// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "solmate/src/utils/SafeTransferLib.sol";
import "solmate/src/tokens/ERC20.sol";
import "../interfaces/IController.sol";
import "../SnackShack.sol";

error Controller_Forbidden();

abstract contract Controller is IController {
    using SafeTransferLib for address payable;
    using SafeTransferLib for ERC20;
    
    SnackShack farm;

    modifier onlyFarm() {
        if (msg.sender != address(farm)) revert Controller_Forbidden();
        _;
    }

    constructor(SnackShack _farm) {
        farm = _farm;
    }

    function _deposit(ERC20 poolToken, address from, uint256 amount) internal {
        if (address(poolToken) != address(0)) {
            poolToken.safeTransferFrom(from, address(this), amount);
        }
    }

    function _withdraw(ERC20 poolToken, address to, uint256 amount) internal {
        if (address(poolToken) == address(0)) {
            payable(to).safeTransferETH(amount);
        } else {
            poolToken.safeTransfer(to, amount);
        }
    }
}