// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "solmate/src/utils/SafeTransferLib.sol";
import "solmate/src/tokens/ERC20.sol";
import "../interfaces/IRewarder.sol";


error DefaultRewarder_NotRewardDistributor();

contract DefaultRewarder is IRewarder {
    using SafeTransferLib for ERC20;
    
    uint256 private immutable rewardMultiplier;
    ERC20 private immutable rewardToken;
    uint256 private constant REWARD_TOKEN_DIVISOR = 1e18;
    address private immutable rewardDistributor;

    modifier onlyRewardDistributor {
        if (msg.sender != rewardDistributor) revert DefaultRewarder_NotRewardDistributor();
        _;
    }

    constructor (uint256 _rewardMultiplier, ERC20 _rewardToken, address _rewardDistributor) {
        rewardMultiplier = _rewardMultiplier;
        rewardToken = _rewardToken;
        rewardDistributor = _rewardDistributor;
    }

    function onSnacksReward(uint256, address, address to, uint256 rewardTokenAmount, uint256) onlyRewardDistributor external virtual override {
        uint256 pendingReward = rewardTokenAmount * rewardMultiplier / REWARD_TOKEN_DIVISOR;
        uint256 rewardBal = rewardToken.balanceOf(address(this));
        if (pendingReward > rewardBal) {
            rewardToken.safeTransfer(to, rewardBal);
        } else {
            rewardToken.safeTransfer(to, pendingReward);
        }
    }
    
    function pendingTokens(uint256, address, uint256 rewardTokenAmount)
        external
        view
        virtual
        override
        returns (ERC20[] memory rewardTokens, uint256[] memory rewardAmounts)
    {
        ERC20[] memory _rewardTokens = new ERC20[](1);
        _rewardTokens[0] = (rewardToken);
        uint256[] memory _rewardAmounts = new uint256[](1);
        _rewardAmounts[0] = rewardTokenAmount* rewardMultiplier / REWARD_TOKEN_DIVISOR;
        return (_rewardTokens, _rewardAmounts);
    } 
}