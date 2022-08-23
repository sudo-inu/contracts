// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "solmate/src/tokens/ERC20.sol";
import "../lssvm/LSSVMPair.sol";
import "../lib/SqrtMath.sol";
import "../SnackShack.sol";
import "../SudoInuLP.sol";
import "./Controller.sol";


error SudoController_InvalidPairAmount();
error SudoController_InvalidEmergencyPrice();

contract SudoController is Controller, Ownable {
    SudoInuLP public immutable lpToken;

    uint96 public fee;
    uint128 public delta;

    address private lastUser;
    uint128 public lastSpotPrice;
    int128 public deltaPerAmount = 15e14; // +10 ETH per 10M liquidity at $1,500 / ETH

    int128 private constant DELTA_PRECISION = 1e18;

    LSSVMPair[] public lpPairs;
    mapping (LSSVMPair => bool) private removedLpPair;

    mapping (address => uint128) public userPrice;
    mapping (address => address) private next;
    mapping (address => address) private prev;
    
    constructor(
        SnackShack _farm,
        SudoInuLP _lpToken,
        uint96 _fee,
        uint128 _delta,
        uint128 _initialSpotPrice,
        int128 _deltaPerAmount
    ) Controller(_farm) {
        lpToken = _lpToken;
        fee = _fee;
        delta = _delta;
        lastSpotPrice = _initialSpotPrice;
        deltaPerAmount = _deltaPerAmount;
    }

    function getPairAmount(LSSVMPair[] memory ownerPairs) public view returns (uint256 totalAmount) {
        for (uint i = 0; i < ownerPairs.length; ++i) {
            totalAmount = totalAmount + lpToken.getPairAmount(ownerPairs[i]);
        }
    }

    function getPairBytes(LSSVMPair[] memory pairs) external pure returns (bytes memory data) {
        address[] memory addresses = new address[](pairs.length);
        for (uint i = 0; i < pairs.length; ++i) {
            addresses[i] = address(pairs[i]);
        }
        return abi.encode(addresses);
    }

    function verifyPairBytes(bytes calldata data) external pure returns (LSSVMPair[] memory pairs) {
        return abi.decode(data, (LSSVMPair[]));
    }

    function _checkPairAmount(LSSVMPair[] memory ownerPairs, uint256 amount) internal view {
        uint256 totalAmount = getPairAmount(ownerPairs);
        if (totalAmount != amount) revert SudoController_InvalidPairAmount();
    }

    function nextSpotPrice(uint128 depositAmount) public view returns (uint128) {
        return uint128(int128(lastSpotPrice) + deltaPerAmount * int128(depositAmount) / DELTA_PRECISION);
    }

    function changeFee(uint96 newFee) external onlyOwner {
        fee = newFee;
    }

    function changeExistingFees(uint96 newFee) external onlyOwner {
        for (uint i = 0; i < lpPairs.length; ++i) {
            if (removedLpPair[lpPairs[i]]) continue;
            lpToken.changeFee(lpPairs[i], newFee);
        }
    }

    function changeDeltaPerAmount(int128 newDeltaPerAmount) external onlyOwner {
        deltaPerAmount = newDeltaPerAmount;
    }

    function onDeposit(
        uint256,
        ERC20,
        uint256 amount,
        address to,
        address,
        bytes calldata data
    ) external virtual override onlyFarm returns (bool success) {
        uint128 newSpotPrice = nextSpotPrice(uint128(amount));

        LSSVMPair[] memory ownerPairs;
        if (data.length != 0) {
            ownerPairs = abi.decode(data, (LSSVMPair[]));
        } else {
            ownerPairs = lpToken.getOwnerPairs(msg.sender);
        }

        _checkPairAmount(ownerPairs, amount);
        lpToken.transferOwnership(address(this), ownerPairs);

        for (uint i = 0; i < ownerPairs.length; ++i) {
            // note: we use the geometric mean of increased liquidity to store less variables
            //       and prevent LP squatting
            uint128 midSpotPrice = SqrtMath.sqrt(uint256(newSpotPrice) * uint256(lastSpotPrice));

            if (lpToken.poolType() == LSSVMPair.PoolType.TRADE) {
                lpToken.changeFee(ownerPairs[i], fee);
            }

            lpToken.changeDelta(ownerPairs[i], delta);
            lpToken.changeSpotPrice(ownerPairs[i], midSpotPrice);
        }

        for (uint i = 0; i < ownerPairs.length; ++i) {
            lpPairs.push(ownerPairs[i]);
        }
        
        if (prev[to] != address(0)) {
            next[prev[to]] = next[to];
            prev[next[to]] = prev[to];

            if (lastUser == to) {
                lastUser = prev[to];
            }
        }

        if (lastUser != address(0)) {
            next[lastUser] = to;
            prev[to] = lastUser;
        }
        
        userPrice[to] = newSpotPrice;
        lastSpotPrice = newSpotPrice;
        lastUser = to;
        
        return true;
    }

    function onWithdraw(
        uint256,
        ERC20,
        uint256 amount,
        address to,
        address from,
        bytes calldata data
    ) external virtual override onlyFarm returns (bool success) {
        LSSVMPair[] memory ownerPairs = abi.decode(data, (LSSVMPair[]));

        _checkPairAmount(ownerPairs, amount);

        lpToken.transferOwnership(to, ownerPairs);

        for (uint i = 0; i < ownerPairs.length; ++i) {
            removedLpPair[ownerPairs[i]] = true;
        }
        
        if (userPrice[from] == lastSpotPrice) {
            lastUser = prev[from];
            lastSpotPrice = userPrice[prev[from]];
        } else {
            next[prev[from]] = next[from];
            prev[next[from]] = prev[from];
        }

        return true;
    }

    /// @dev can be used in an emergency to move all spot prices down (to zero, for example).
    ///      if a pool spot price is dropped, it cannot be later manually raised!
    ///      note: this will break the ordering of deposits, make sure this is necessary.
    function emergencyDropSpot(uint128 newSpotPrice) external onlyOwner {
        if (newSpotPrice >= lastSpotPrice) revert SudoController_InvalidEmergencyPrice();

        lastSpotPrice = newSpotPrice;
        
        for (uint i = 0; i < lpPairs.length; ++i) {
            if (removedLpPair[lpPairs[i]]) continue;
            lpToken.changeSpotPrice(lpPairs[i], newSpotPrice);
        }

        address prev_iter = lastUser;

        while (prev_iter != address(0)) {
            userPrice[prev_iter] = newSpotPrice;
            prev_iter = prev[prev_iter];
        }
    }
}