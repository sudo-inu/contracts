// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "solmate/src/tokens/ERC20.sol";
import "../SnackShack.sol";
import "./Controller.sol";


contract DefaultController is Controller {
    constructor(SnackShack _farm) Controller(_farm) {}

    function onDeposit(
        uint256,
        ERC20 poolToken,
        uint256 amount,
        address,
        address from,
        bytes calldata
    ) external virtual override onlyFarm returns (bool success) {
        _deposit(poolToken, from, amount);
        return true;
    }

    function onWithdraw(
        uint256,
        ERC20 poolToken,
        uint256 amount,
        address to,
        address,
        bytes calldata
    ) external virtual override onlyFarm returns (bool success) {
        _withdraw(poolToken, to, amount);
        return true;
    }
}