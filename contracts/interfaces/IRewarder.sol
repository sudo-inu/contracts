// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "solmate/src/tokens/ERC20.sol";

interface IRewarder {
    function onSnacksReward(uint256 pid, address user, address recipient, uint256 snacksAmount, uint256 newLpAmount) external;
    function pendingTokens(uint256 pid, address user, uint256 snacksAmount) external view returns (ERC20[] memory, uint256[] memory);
}