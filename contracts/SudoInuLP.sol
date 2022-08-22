// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "solmate/src/tokens/ERC20.sol";
import "./lssvm/ILSSVMPairFactoryLike.sol";
import "./lssvm/lib/IOwnershipTransferCallback.sol";
import "./lssvm/bonding-curves/ICurve.sol";
import "./lssvm/LSSVMPair.sol";
import "./lib/Multicall.sol";


error SudoInuLP_Forbidden();
error SudoInuLP_NewOwnerZeroAddress();
error SudoInuLP_NonTransferrable();

contract SudoInuLP is ERC20, ReentrancyGuard, IOwnershipTransferCallback, Multicall {

    address private constant ZERO_ADDRESS = address(0);

    IERC721 public immutable nft;
    ILSSVMPairFactoryLike public immutable factory;
    ICurve public immutable curve;
    LSSVMPair.PoolType public immutable poolType;
    uint128 public immutable spotPrice;
    bool public immutable allowFractional;

    mapping (address => uint256) public numPairs;
    mapping (LSSVMPair => address) public pairOwner;
    mapping (LSSVMPair => uint256) public pairAmount;

    mapping (LSSVMPair => mapping (address => bool)) public transferApprovals;

    mapping (address => mapping (LSSVMPair => LSSVMPair)) public ownerPairsPrev;
    mapping (address => mapping (LSSVMPair => LSSVMPair)) public ownerPairsNext;
    mapping (address => LSSVMPair) public lastPair;

    modifier onlyOwner(LSSVMPair pair) {
        if (msg.sender != pairOwner[pair]) revert SudoInuLP_Forbidden();
        _;
    }

    struct ConstructorArgs {
        IERC721 nft;
        ILSSVMPairFactoryLike factory;
        ICurve curve;
        LSSVMPair.PoolType poolType;
        uint128 spotPrice;
        bool allowFractional;
    }

    constructor(ConstructorArgs memory args) ERC20("Sudo Inu LP", "SUDO-LP", 18) {
        nft = args.nft;
        factory = args.factory;
        curve = args.curve;
        poolType = args.poolType;
        spotPrice = args.spotPrice;
        allowFractional = args.allowFractional;
    }

    function getPairAmount(LSSVMPair pair) public view returns (uint256 amount) {
        amount = pairAmount[pair];
    }

    function getOwnerPairs(address owner) public view returns (LSSVMPair[] memory pairs) {
        pairs = new LSSVMPair[](numPairs[owner]);
        LSSVMPair pair = lastPair[owner];
        for (uint i = 0; i < numPairs[owner]; i++) {
            pairs[i] = pair;
            pair = ownerPairsPrev[owner][pair];
        }
    }

    function onOwnershipTransfer(address oldOwner) external override nonReentrant {
        LSSVMPair pair = LSSVMPair(msg.sender);

        if (pair.nft() != nft
            || pair.factory() != factory
            || pair.poolType() != poolType
            || pair.bondingCurve() != curve
        ) {
            // Invalid deposit
            pair.transferOwnership(oldOwner);
            return;
        }

        _deposit(pair, oldOwner);
    }

    function _deposit(LSSVMPair pair, address to) internal {
        uint256 amount = 0;

        if (poolType != LSSVMPair.PoolType.NFT) {
            if (allowFractional) {
                amount += address(pair).balance;
            } else {
                amount += address(pair).balance / spotPrice * spotPrice;
            }
        }
        
        if (poolType != LSSVMPair.PoolType.TOKEN) {
            amount += spotPrice * pair.getAllHeldIds().length;
        }

        if (amount < spotPrice) {
            // Insufficient deposit size
            pair.transferOwnership(to);
            return;
        }
        
        pairOwner[pair] = to;

        ownerPairsNext[to][lastPair[to]] = pair;
        ownerPairsPrev[to][pair] = lastPair[to];
        lastPair[to] = pair;
        pairAmount[pair] = amount;
        numPairs[to]++;

        _mint(to, amount);
    }

    function withdraw(LSSVMPair pair, address to) public onlyOwner(pair) nonReentrant {
        pair.transferOwnership(to);
        numPairs[pairOwner[pair]]--;

        _burn(to, pairAmount[pair]);
        
        if (pair == lastPair[to]) {
            lastPair[to] = ownerPairsPrev[to][pair];
        } else {
            ownerPairsNext[to][ownerPairsPrev[to][pair]] = ownerPairsNext[to][pair];
            ownerPairsPrev[to][ownerPairsNext[to][pair]] = ownerPairsPrev[to][pair];
        }
    }

    function withdrawMultiple(LSSVMPair[] memory pairs, address to) external nonReentrant {
        for (uint i = 0; i < pairs.length; ++i) {
            withdraw(pairs[i], to);
        }
    }

    function changeFee(LSSVMPair pair, uint96 newFee) external onlyOwner(pair) {
        pair.changeFee(newFee);
    }

    function changeDelta(LSSVMPair pair, uint128 newDelta) external onlyOwner(pair) {
        pair.changeDelta(newDelta);
    }

    function changeSpotPrice(LSSVMPair pair, uint128 newSpotPrice) external onlyOwner(pair) {
        pair.changeSpotPrice(newSpotPrice);
    }

    /// @dev Transfers ownership of a the LP token to a new account (`to`).
    /// Disallows setting to the zero address as a way to more gas-efficiently avoid reinitialization
    /// Can only be called by the current owner.
    function transferOwnership(address to, LSSVMPair[] calldata pairs) public nonReentrant {
        if (to == address(0)) revert SudoInuLP_NewOwnerZeroAddress();

        for (uint i = 0; i < pairs.length; ++i) {
            address prevOwner = pairOwner[pairs[i]];
            
            if (msg.sender != prevOwner && !transferApprovals[pairs[i]][msg.sender])
                revert SudoInuLP_Forbidden();

            // Withdraw from prev owner
            numPairs[prevOwner]--;

            _burn(prevOwner, pairAmount[pairs[i]]);
            
            if (pairs[i] == lastPair[prevOwner]) {
                lastPair[prevOwner] = ownerPairsPrev[prevOwner][pairs[i]];
            } else {
                ownerPairsNext[prevOwner][ownerPairsPrev[prevOwner][pairs[i]]] = ownerPairsNext[prevOwner][pairs[i]];
                ownerPairsPrev[prevOwner][ownerPairsNext[prevOwner][pairs[i]]] = ownerPairsPrev[prevOwner][pairs[i]];
            }

            // Deposit to new owner
            pairOwner[pairs[i]] = to;
            numPairs[to]++;
            
            _mint(to, pairAmount[pairs[i]]);
            
            ownerPairsNext[to][lastPair[to]] = pairs[i];
            ownerPairsPrev[to][pairs[i]] = lastPair[to];
            lastPair[to] = pairs[i];
        }
    }
    
    /// @dev Pre-approves a `transferrer` to transfer ownership of the LP token, for composability.
    function approveTransferrer(address transferrer, LSSVMPair[] calldata pairs) public {
        if (transferrer == address(0)) revert SudoInuLP_NewOwnerZeroAddress();

        for (uint i = 0; i < pairs.length; ++i) {
            if (msg.sender != pairOwner[pairs[i]])
                revert SudoInuLP_Forbidden();

            transferApprovals[pairs[i]][transferrer] = true;
        }
    }

    /// @dev Revokes pre-approval of a `transferrer`.
    function revokeTransferrer(address transferrer, LSSVMPair[] calldata pairs) public {
        for (uint i = 0; i < pairs.length; ++i) {
            if (msg.sender != pairOwner[pairs[i]])
                revert SudoInuLP_Forbidden();

            transferApprovals[pairs[i]][transferrer] = false;
        }
    }

    function _beforeTokenTransfer(address, address, uint256) internal pure {
        revert SudoInuLP_NonTransferrable();
    }
}