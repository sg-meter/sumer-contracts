import EventEmitter from "events";
import { AccountListener } from "./AccountListener";
import { PriceListener } from "./PriceListener";
import BN from "bignumber.js";
import {
  PotentialRepay,
  PotentialSeize,
  AuditorConfig,
  AuditorInterface,
  ExecMethod,
} from "./types";
import { Head, Account, IPlan, Plan, Position } from "../model";
import { Logger } from "pino";
import { loadProvider } from "../const";
import * as Sumer from "@meterio/sumer-js";
import {
  Comptroller,
  Comptroller__factory,
} from "@meterio/sumer-js/dist/nodejs/typechain";
import { MetadataUpdater } from "./MetadataUpdater";
import { MetadataRepo, PositionRepo, PriceRepo } from "../repo";
import { Notifier } from "./Notifier";
import PromisePool from "@supercharge/promise-pool";
import { ComptrollerSimulator } from "./ComptrollerSimulator";
import { ConfigRepo } from "../repo/config.repo";
export class Auditor extends EventEmitter implements AuditorInterface {
  private network: string;
  private chainId: number;

  private accountListener: AccountListener;
  private priceListener: PriceListener;
  private metadataUpdater: MetadataUpdater;
  private notifier: Notifier;
  private simulator: ComptrollerSimulator;
  private config: AuditorConfig;
  private log: Logger;

  private priceRepo = new PriceRepo();
  private metadataRepo = new MetadataRepo();
  private configRepo = new ConfigRepo();

  private comptroller: Comptroller;
  insolvency: { [key: string]: any } = {};

  constructor(rootLogger: Logger, config: AuditorConfig) {
    super();
    const provider = loadProvider(config.network);
    if (!provider) {
      throw new Error(`not supported network: ${config.rpcUrl}`);
    }

    this.config = config;
    this.network = config.network;
    this.chainId = config.chainId;
    this.accountListener = new AccountListener(
      rootLogger,
      config.network,
      config.chainId,
      config.startBlock,
      config.accountUpdateInterval,
      config.accountFastForwardInterval,
      config.accountFastForwardWindow
    );
    this.priceListener = new PriceListener(
      rootLogger,
      config.network,
      config.chainId,
      config.priceUpdateInterval
    );
    this.metadataUpdater = new MetadataUpdater(
      rootLogger,
      config.network,
      config.chainId,
      config.metadataUpdateInterval
    );
    this.notifier = new Notifier(
      rootLogger,
      this.network,
      this.chainId,
      config.liquidationNotifyInterval,
      config.haltCheckInterval
    );

    this.simulator = new ComptrollerSimulator(
      rootLogger,
      this.network,
      this.chainId
    );
    this.log = rootLogger.child({});
    const cAddr = Sumer.util.getAddress("Comptroller", config.network);
    this.comptroller = Comptroller__factory.connect(cAddr, provider);
  }

  async init() {
    this.priceListener.on("priceChange", this.auditAllAccounts.bind(this));
    await this.metadataUpdater.init();
    await this.accountListener.init();

    await this.priceListener.init();
    await this.notifier.init();
    await this.simulator.init();
    this.log.info("auditor initialized");

    this.auditAllAccounts();
  }

  async auditAffectedAccounts(accounts: string[]) {
    this.log.info(
      `start auditing affected ${accounts.length} accounts on chain ${this.network}(${this.chainId})`
    );
    await PromisePool.for(accounts)
      .withConcurrency(30)
      .process(async (addr, index, pool) => {
        try {
          await this.auditAccount(addr, false);
        } catch (e) {
          this.log.error(e, `error in auditing account ${addr}`);
        }
      });
  }

  async auditAllAccounts() {
    const accounts = await Position.distinct("owner", {
      chainId: this.chainId,
    }).exec();

    this.log.info(
      `start auditing all of ${accounts.length} accounts on chain ${this.network}(${this.chainId})`
    );
    await PromisePool.for(accounts)
      .withConcurrency(30)
      .process(async (addr, index, pool) => {
        try {
          await this.auditAccount(addr, true);
        } catch (e) {
          this.log.error(e, `error in auditing account ${addr}`);
        }
      });
  }

  public async auditAccount(address: string, simulate: boolean = false) {
    this.log.info(
      `audit account ${address} with ${simulate ? "simulated" : "onchain"} calc`
    );

    let res: { liquidity: bigint; shortfall: bigint };
    if (simulate) {
      res = await this.getHypoFromChain(address);
      const resOnChain = await this.getHypoFromChain(address);
      if (resOnChain.liquidity != res.liquidity) {
        this.log.warn(
          `Liquidity calc mismatch, sim:${res.liquidity}, onchain:${resOnChain.liquidity}`
        );
      } else {
        this.log.debug(
          `Liquidity calc matches! sim:${res.liquidity}, onchain:${resOnChain.liquidity}`
        );
      }
      if (resOnChain.shortfall != res.shortfall) {
        this.log.warn(
          `Shortfall calc mismatch, sim:${res.shortfall}, onchain:${resOnChain.shortfall}`
        );
      } else {
        this.log.debug(
          `Shortfall calc matches! sim:${res.shortfall}, onchain:${resOnChain.shortfall}`
        );
      }
    } else {
      res = await this.getHypoFromSimulator(address);
    }

    const insolvent = res.shortfall > BigInt(0);

    await Account.findOneAndUpdate(
      { chainId: this.chainId, address },
      {
        chainId: this.chainId,
        address,
        insolvent,
        liquidity: new BN(res.liquidity.toString()).div(1e18).toFixed(6),
        shortfall: new BN(res.shortfall.toString()).div(1e18).toFixed(6),
      },
      {
        new: true,
        upsert: true,
        overwrite: true,
      }
    );

    if (insolvent) {
      this.log.info(
        { res },
        `found insolvent account ${address}, start to generate plans`
      );
      await this.generatePlans(address);
    } else {
      this.log.info(`audited account ${address}: healthy `);
      const delRes = await Plan.deleteMany({
        chainId: this.chainId,
        account: address,
      });
      if (delRes.deletedCount > 0) {
        this.log.info(
          `account ${address} is not insolvent anymore ${insolvent}, delete all the generated plans`,
          res.shortfall,
          new BN(res.shortfall.toString()).toFixed()
        );
      }
    }
  }

  private async generatePlans(address: string) {
    const minCloseValue = await this.configRepo.findByID(
      this.chainId,
      "minclosevalue"
    );
    const supplys = await Position.find({
      chainId: this.chainId,
      owner: address,
      supply: { $ne: new BN(0) },
    });
    const borrows = await Position.find({
      chainId: this.chainId,
      owner: address,
      borrow: { $ne: new BN(0) },
    });

    const seizes: PotentialSeize[] = await Promise.all(
      supplys.map(async (pos) => {
        // const price = this.priceListener.getPriceFor(pos.tokenAddress);
        const price = await this.priceRepo.findByID(
          this.chainId,
          pos.tokenAddress
        );
        this.log.info(
          `find metadata with ${this.chainId}, ${pos.tokenAddress}`
        );
        const metadata = await this.metadataRepo.findByID(
          this.chainId,
          pos.tokenAddress
        );
        const maxSeizeTokens = new BN(
          new BN(pos.supply).times(metadata.exchangeRate).toFixed(0, 1)
        );
        // this.log.info(`seize price ${price.underlyPrice} for ${metadata.symbol}`);
        return {
          price: new BN(price.current),
          exchangeRate: new BN(metadata.exchangeRate),
          maxSeizeTokens: new BN(maxSeizeTokens).div(
            `1e${metadata.underlyDecimals}`
          ),
          maxSeizeUSD: maxSeizeTokens
            .times(price.current)
            .div(`1e${metadata.underlyDecimals}`),
          tokenAddress: pos.tokenAddress,
        };
      })
    );

    const repays: PotentialRepay[] = await Promise.all(
      borrows.map(async (pos) => {
        // const price = this.priceListener.getPriceFor(pos.tokenAddress);
        const price = await this.priceRepo.findByID(
          this.chainId,
          pos.tokenAddress
        );
        const metadata = await this.metadataRepo.findByID(
          this.chainId,
          pos.tokenAddress
        );
        const actualCloseFactor = new BN(metadata.closeFactor).isGreaterThan(1)
          ? 1
          : metadata.closeFactor;

        let maxRepayTokens = new BN(
          new BN(pos.borrow)
            .div(metadata.exchangeRate)
            .times(actualCloseFactor)
            .toFixed(0, 1)
        );
        console.log("minclosevalue: ", minCloseValue.value);
        let maxRepayUSD = maxRepayTokens
          .times(price.current)
          .div(`1e${metadata.underlyDecimals}`);
        if (maxRepayUSD.toNumber() < Number(minCloseValue.value)) {
          maxRepayTokens = new BN(
            new BN(pos.borrow).div(metadata.exchangeRate).toFixed(0)
          );
          maxRepayUSD = maxRepayTokens
            .times(price.current)
            .div(`1e${metadata.underlyDecimals}`);
        }
        // this.log.info(`repay price ${price.underlyPrice} for ${metadata.symbol}`);
        return {
          price: new BN(price.current),
          maxRepayTokens: maxRepayTokens.div(`1e${metadata.underlyDecimals}`),
          maxRepayUSD,
          tokenAddress: pos.tokenAddress,
        };
      })
    );

    repays.sort((a, b) => (a.maxRepayUSD.gt(b.maxRepayUSD) ? -1 : 1));
    seizes.sort((a, b) => (a.maxSeizeUSD.gt(b.maxSeizeUSD) ? -1 : 1));

    this.log.info("repays: ");
    for (const r of repays) {
      this.log.info(
        `tokenAddr:${
          r.tokenAddress
        }, price: ${r.price.toFixed()}, maxRepayTokens:${r.maxRepayTokens.toFixed()}, maxRepayUSD: ${r.maxRepayUSD.toFixed()}`
      );
    }
    this.log.info("seizes: ");
    for (const s of seizes) {
      this.log.info(
        `tokenAddr:${
          s.tokenAddress
        }, price:${s.price.toFixed()}, maxSeizeTokens:${s.maxSeizeTokens.toFixed()}, maxSeizeUSD: ${s.maxSeizeUSD.toFixed()}`
      );
    }

    const existPlans = await Plan.find({ account: address });
    let execMethodMap = {};
    existPlans.map((p) => {
      const key = `${p.account}_${p.repayTokenAddress}_${p.seizeTokenAddress}`;
      execMethodMap[key] = p.execMethod;
    });

    let plans: IPlan[] = [];
    for (const repay of repays) {
      const repayMetadata = await this.metadataRepo.findByID(
        this.chainId,
        repay.tokenAddress
      );
      for (const seize of seizes) {
        let profitUSD = new BN(0);
        let protocolSeizeUSD = new BN(0);
        let protocolSeizeTokens = new BN(0);
        let actualRepay = new BN(0);
        let actualSeize = new BN(0);
        const seizeMetadata = await this.metadataRepo.findByID(
          this.chainId,
          seize.tokenAddress
        );

        let liquidationIncentive = repayMetadata.heteroLiquidationIncentive;
        if (repayMetadata.groupId == seizeMetadata.groupId) {
          if (repayMetadata.isCToken) {
            liquidationIncentive = repayMetadata.homoLiquidationIncentive;
          } else {
            liquidationIncentive = repayMetadata.sutokenLiquidationIncentive;
          }
        }
        const protocolShare = new BN(seizeMetadata.protocolSeizeShare);
        const userShare = new BN(1).minus(seizeMetadata.protocolSeizeShare);
        console.log("liquidation incentive: ", liquidationIncentive);
        console.log(
          `maxRepayUSD:${repay.maxRepayUSD.toFixed()}, maxSeizeUSD:${seize.maxSeizeUSD.toFixed()}`
        );
        const seizeTokenPrice = await this.priceRepo.findByID(
          this.chainId,
          seize.tokenAddress
        );
        if (repay.maxRepayUSD.gt(seize.maxSeizeUSD)) {
          console.log(`use maxSeizeUSD to calculate`);
          actualSeize = seize.maxSeizeTokens;
          console.log(`actual seize: ${actualSeize}`);
          const repayTokenPrice = await this.priceRepo.findByID(
            this.chainId,
            repay.tokenAddress
          );
          actualRepay = seize.maxSeizeUSD
            .div(new BN(liquidationIncentive).plus(1))
            .div(repayTokenPrice.current);
          console.log(
            `actual repay: ${actualRepay}, liquidationIncentive: ${liquidationIncentive}, ${userShare}`
          );
          profitUSD = seize.maxSeizeUSD
            .div(new BN(liquidationIncentive).plus(1))
            .times(liquidationIncentive)
            .times(userShare);
          protocolSeizeUSD = seize.maxSeizeUSD
            .times(liquidationIncentive)
            .times(protocolShare);
          protocolSeizeTokens = protocolSeizeUSD.div(seizeTokenPrice.current);

          // console.log(`repayTokenPrice: ${repayTokenPrice.underlyPrice}`, repay.tokenAddress);
          // console.log(`actualRepay: ${actualRepay.toFixed()}, profit:${profit.toFixed()}`);
        } else {
          console.log(`use maxRepayUSD to calculate`);
          actualRepay = repay.maxRepayTokens;
          console.log(`actual repay: ${actualRepay}`);
          // console.log(`seizeTokenPrice: ${seizeTokenPrice.underlyPrice}`, seize.tokenAddress);
          actualSeize = repay.maxRepayUSD
            .times(new BN(liquidationIncentive).times(userShare).plus(1))
            .div(seizeTokenPrice.current);
          console.log(
            `actual seize: ${actualSeize}, liquidationIncentive: ${liquidationIncentive}, ${userShare}`
          );
          profitUSD = repay.maxRepayUSD
            .times(liquidationIncentive)
            .times(userShare);
          protocolSeizeUSD = repay.maxRepayUSD
            .times(liquidationIncentive)
            .times(protocolShare);
          protocolSeizeTokens = protocolSeizeUSD.div(seizeTokenPrice.current);

          // console.log(`actualSeize: ${actualRepay.toFixed()}, profit:${profit.toFixed()}`);
        }

        const key = `${address}_${repay.tokenAddress}_${seize.tokenAddress}`;
        let execMethod = ExecMethod.Unknown;
        if (key in execMethodMap) {
          execMethod = execMethodMap[key];
        }
        const plan = {
          chainId: this.config.chainId,
          account: address,
          repayTokenAddress: repay.tokenAddress,
          repayTokens: actualRepay,
          seizeTokenAddress: seize.tokenAddress,
          seizeTokens: actualSeize,
          profitUSD: profitUSD.toNumber(),
          protocolSeizeUSD: protocolSeizeUSD.toNumber(),
          protocolSeizeTokens: protocolSeizeTokens,
          execMethod,
        } as IPlan;
        this.log.info(
          `new plan generated: borrower ${address}, repay ${actualRepay.toFixed()} ${
            repay.tokenAddress
          }, seize ${actualSeize.toFixed()} ${seize.tokenAddress}`
        );
        plans.push(plan);
      }
    }

    this.log.info(`generated ${plans.length} plans`);
    const deleteRes = await Plan.deleteMany({
      chainId: this.chainId,
      account: address,
    });
    this.log.info(`deleted ${deleteRes.deletedCount} plans in db`);
    // pick top 5 plans
    plans
      .filter((p) => Number(p.profitUSD) > 0)
      .filter((p) => Number(p.repayTokens) > 0)
      .filter((p) => Number(p.seizeTokens) > 0)
      .sort((a, b) => (a.profitUSD > b.profitUSD ? -1 : 1));
    plans = plans.slice(0, 5);

    // const insertRes = await Plan.insertMany(plans);
    for (const p of plans) {
      const newPlan = new Plan(p);
      this.log.info(`save plan ${JSON.stringify(newPlan.toJSON())}`);
      await newPlan.save();
    }
    this.log.info(`saved ${plans.length} plans`);

    this.emit("insolventAccount", { account: address, plans });
  }

  calc(collateralVal: BN, borrowVal: BN, collateralRate: string) {
    const collateralizedLoan = collateralVal.times(collateralRate).div(1e18);
    const usedCollateral = borrowVal.times(1e18).div(collateralRate);
    return { collateralizedLoan, usedCollateral };
  }

  async getHypoFromChain(address: string) {
    const res = await this.comptroller.getHypotheticalAccountLiquidity(
      address,
      "0x0000000000000000000000000000000000000000",
      0,
      0
    );
    const liquidity = res[0];
    const shortfall = res[1];
    return { liquidity, shortfall };
  }

  async getHypoFromSimulator(address: string) {
    const res = await this.simulator.getSimulatedHypotheticalAccountLiquidity(
      address,
      "0x0000000000000000000000000000000000000000"
    );
    const liquidity = res[0];
    const shortfall = res[1];
    return { liquidity, shortfall };
  }

  start() {
    this.accountListener.on(
      "accountsChange",
      this.auditAffectedAccounts.bind(this)
    );

    this.priceListener.start();
    this.metadataUpdater.start();
    this.accountListener.start();
    this.notifier.start();
  }

  async stop() {
    this.accountListener.removeAllListeners();
    this.priceListener.removeAllListeners();

    this.priceListener.stop();
    this.metadataUpdater.stop();
    await this.accountListener.stop();
  }
}
