// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IInfraredVault {
  /**
   * @notice A struct to hold a user's reward information
   * @param token The address of the reward token
   * @param amount The amount of reward tokens
   */
  struct UserReward {
    address token;
    uint256 amount;
  }

  function stakingToken() external view returns (address);

  /**
   * @notice Returns all reward tokens
   * @return An array of reward token addresses
   */
  function getAllRewardTokens() external view returns (address[] memory);

  /**
   * @notice Claims all pending rewards for a specified user
   * @dev Iterates through all reward tokens and transfers any accrued rewards to the user
   * @param _user The address of the user to claim rewards for
   */
  function getRewardForUser(address _user) external;

  /**
   * @notice Returns all rewards for a user
   * @notice Only up to date since the `lastUpdateTime`
   * @param _user The address of the user
   * @return An array of UserReward structs
   */
  function getAllRewardsForUser(address _user) external view returns (UserReward[] memory);

  /**
   * @notice Stakes tokens into the contract
   * @param amount The amount of tokens to stake
   * @dev Transfers `amount` of staking tokens from the user to this contract
   */
  function stake(uint256 amount) external;

  /**
   * @notice Withdraws staked tokens from the contract
   * @param amount The amount of tokens to withdraw
   * @dev Transfers `amount` of staking tokens back to the user
   */
  function withdraw(uint256 amount) external;

  function earned(address account, address rewardToken) external view returns (uint256);
}
