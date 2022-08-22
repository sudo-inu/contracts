// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "solmate/src/tokens/ERC20.sol";

interface IController {
    function onDeposit(
        uint256 pid,
        ERC20 poolToken,
        uint256 amount,
        address to,
        address from,
        bytes calldata data
    ) external returns (bool success);
    function onWithdraw(
        uint256 pid,
        ERC20 poolToken,
        uint256 amount,
        address to,
        address from,
        bytes calldata data
    ) external returns (bool success);
}