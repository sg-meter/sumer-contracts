// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ITimelock {
  /** @notice Event emitted when a new time-lock agreement is created
   * @param agreementId ID of the created agreement
   * @param beneficiary Address of the beneficiary
   * @param asset Address of the asset
   * @param actionType Type of action for the time-lock
   * @param amount  amount
   * @param timestamp Timestamp when the assets entered timelock
   */
  event AgreementCreated(
    uint256 indexed agreementId,
    address indexed beneficiary,
    address indexed asset,
    TimeLockActionType actionType,
    uint256 amount,
    uint256 timestamp
  );

  /** @notice Event emitted when a time-lock agreement is claimed
   * @param agreementId ID of the claimed agreement
   * @param beneficiary Beneficiary of the claimed agreement
   * @param asset Address of the asset
   * @param actionType Type of action for the time-lock
   * @param amount amount
   * @param beneficiary Address of the beneficiary
   */
  event AgreementClaimed(
    uint256 indexed agreementId,
    address indexed beneficiary,
    address indexed asset,
    TimeLockActionType actionType,
    uint256 amount
  );

  /** @notice Event emitted when a time-lock agreement is frozen or unfrozen
   * @param agreementId ID of the affected agreement
   * @param value Indicates whether the agreement is frozen (true) or unfrozen (false)
   */
  event AgreementFrozen(uint256 agreementId, bool value);

  /** @notice Event emitted when the entire TimeLock contract is frozen or unfrozen
   * @param value Indicates whether the contract is frozen (true) or unfrozen (false)
   */
  event TimeLockFrozen(bool value);

  /**
   * @dev Emitted during rescueAgreement()
   * @param agreementId The rescued agreement Id
   * @param underlyToken The adress of the underlying token
   * @param to The address of the recipient
   * @param underlyAmount The amount being rescued
   **/
  event RescueAgreement(uint256 agreementId, address indexed underlyToken, address indexed to, uint256 underlyAmount);

  enum TimeLockActionType {
    BORROW,
    REDEEM
  }
  struct Agreement {
    bool isFrozen;
    TimeLockActionType actionType;
    address cToken;
    address beneficiary;
    uint48 timestamp;
    uint256 agreementId;
    uint256 underlyAmount;
  }

  function createAgreement(
    TimeLockActionType actionType,
    uint256 underlyAmount,
    address beneficiary
  ) external returns (uint256);

  function consumeValuePreview(uint256 underlyAmount, address cToken) external view returns (bool);
  function consumeValue(uint256 underlyAmount) external;
}
