// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "solmate/src/utils/SafeTransferLib.sol";
import "solmate/src/tokens/ERC20.sol";
import {ABDKMath64x64} from "abdk-libraries-solidity/ABDKMath64x64.sol";
import "./interfaces/IController.sol";
import "./interfaces/IRewarder.sol";
import "./lssvm/lib/ReentrancyGuard.sol";
import "./lib/Multicall.sol";
import "./lib/SqrtMath.sol";
import "./SnackToken.sol";


error SnackShack_Forbidden();
error SnackShack_InflationTooHigh();
error SnackShack_AlreadyStarted();
error SnackShack_FailedDepositCallback();
error SnackShack_FailedWithdrawCallback();

contract SnackShack is Ownable, ReentrancyGuard, Multicall {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for SnackToken;
    using ABDKMath64x64 for int128;

    enum FarmType {
        STANDARD,
        SCALED
    }

    /// @notice Info of each user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of SNACK entitled to the user.
    /// `depositTimestamp` The number of the block the user deposited in.
    ///     @dev `depositTimestamp` is used to scale down rewards per user,
    ///           based on the length of the deposit, to incentivize new
    ///           deposits.
    ///     note: scaling of rewards by `depositTimestamp` is only done within
    ///           old deposits are incentivized to stay staked by maintaining
    ///           a lower buy wall / higher-priced sell liquidity.
    /// `prevElapsed` Enables calculating the geo-mean between updates.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
        uint64 depositTimestamp;
        uint64 prevElapsed;
    }

    /// @notice Info of each pool.
    /// `totalSupply` Total supply of tokens in this pool.
    ///     @dev: tracking `totalSupply` enables multiple pools per token.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of SNACK to distribute per second.
    struct PoolInfo {
        uint256 totalSupply;
        uint128 accSnacksPerShare;
        uint64 lastRewardTimestamp;
        uint64 allocPoint;
    }

    /// @notice Address of SNACK ERC-20 contract.
    SnackToken public immutable SNACK;

    /// @notice Address of the development fund / project treasury.
    address public treasury;

    /// @notice Info of each pool.
    PoolInfo[] public poolInfo;
    /// @notice Type of farm: STANDARD OR SCALED.
    FarmType[] public farmType;
    /// @notice Address of the token for a pool.
    ERC20[] public poolToken;
    /// @notice Address of each `IRewarder` contract.
    IRewarder[] public rewarder;
    /// @notice Address of each `Controller` contract.
    IController[] public controller;

    /// @notice Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 public snacksPerSecond = 1e21;
    uint256 private constant ACC_SNACK_PRECISION = 1e12;

    int128 internal constant ONE_64x64 = 0x10000000000000000; // 1
    int128 internal constant MULTIPLIER_DECAY_RATE = 0x9d775c4669a9; // 0.00000938572, (50% in 1 day)
    
    uint256 private constant MIN_REWARD_MULTIPLIER = 1e12; // min = 1x
    uint256 private constant REWARD_SCALE = 9e12; // scale = 10x - 1x = 9x
    uint256 private constant MIN_REWARD_TIME = 604800; // t = 7 days * 24 hours * 60 mins * 60 seconds

    uint64 public startTime;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardBlock, uint256 lpSupply, uint256 accSnacksPerShare);
    event LogPoolAddition(
        uint256 indexed pid,
        uint256 allocPoint,
        ERC20 indexed token,
        IController indexed controller,
        IRewarder rewarder,
        FarmType farmType
    );
    event LogSetPool(
        uint256 indexed pid,
        uint256 allocPoint,
        IController indexed controller,
        IRewarder indexed rewarder,
        bool overwrite
    );

    event DepositFailed(string indexed message);
    event WithdrawalFailed(string indexed message);

    modifier onlyOwnerOrTreasury() {
        if (msg.sender != owner() && msg.sender != treasury) revert SnackShack_Forbidden();
        _;
    }

    /// @param _snack The SNACK token contract address.
    constructor(SnackToken _snack, address _treasury) {
        SNACK = _snack;
        treasury = _treasury;
        startTime = uint64(block.timestamp + 10 minutes);
    }

    /// @notice Returns the number of pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Returns the `controller` address which should be approved for this pool.
    function approvalTarget(uint256 pid) public view returns (address) {
        return address(controller[pid]);
    }

    /// @notice Returns the reward multiplier for a user, scaled down based on the amount of
    ///         time their liquidity has been in the pool.
    ///         note: only used for pools with FarmType.SCALING
    function userMultiplier(uint256 pid, address _user) public view returns (uint256 multiplier) {
        UserInfo memory user = userInfo[pid][_user];
        return _userMultiplier(user);
    }

    function _userMultiplier(UserInfo memory user) internal view returns (uint256 multiplier) {
        // note: we use the geometric mean of elapsed time, otherwise the optimal behavior would be
        //       to claim rewards as often as possible, but this only works for whales to whom
        //       gas is a marginal fee
        uint256 elapsed = SqrtMath.sqrt(
            uint256(user.prevElapsed + uint64(block.timestamp) - user.depositTimestamp)
                * uint256(user.prevElapsed > 0 ? user.prevElapsed : 1)
        );
        
        // note: STANDARD pool type has multiplier of 1
        if (user.depositTimestamp == 0 || elapsed > MIN_REWARD_TIME) {
            return MIN_REWARD_MULTIPLIER;
        }

        return MIN_REWARD_MULTIPLIER + ONE_64x64.sub(MULTIPLIER_DECAY_RATE).pow(elapsed).mulu(REWARD_SCALE);
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _farmType FarmType of the pool.
    /// @param _token Address of the LP ERC-20 token.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param _controller Address of the controller delegate.
    function add(uint256 allocPoint, FarmType _farmType, ERC20 _token, IRewarder _rewarder, IController _controller)
        public
        onlyOwner
    {
        uint64 lastRewardTimestamp = block.timestamp > startTime ? uint64(block.timestamp) : startTime;
        totalAllocPoint = totalAllocPoint + allocPoint;

        farmType.push(_farmType);
        poolToken.push(_token);
        controller.push(_controller);
        rewarder.push(_rewarder);

        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: uint64(allocPoint),
            lastRewardTimestamp: lastRewardTimestamp,
            accSnacksPerShare: 0
        }));

        emit LogPoolAddition(poolToken.length - 1, allocPoint, _token, _controller, _rewarder, _farmType);
    }

    /// @notice Update the given pool's SNACK allocation point and `IRewarder` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param _controller Address of the controller delegate.
    /// @param overwrite True if _rewarder/controller should be `set`. Otherwise `_rewarder`/`controller` are ignored.
    function set(uint256 _pid, uint256 _allocPoint, IRewarder _rewarder, IController _controller, bool overwrite)
        public
        onlyOwner
    {
        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = uint64(_allocPoint);

        if (overwrite) {
            rewarder[_pid] = _rewarder;
            controller[_pid] = _controller;
        }

        emit LogSetPool(
            _pid,
            _allocPoint,
            overwrite ? _controller : controller[_pid],
            overwrite ? _rewarder : rewarder[_pid],
            overwrite
        );
    }

    /// @notice Delay the start time
    function setStartTime(uint64 _startTime) public onlyOwnerOrTreasury {
        if (block.timestamp > startTime) revert SnackShack_AlreadyStarted();
        if (block.timestamp > _startTime) revert SnackShack_AlreadyStarted();
        startTime = _startTime;
    }

    /// @notice Update the treasury address
    function setTreasury(address _treasury) public onlyOwnerOrTreasury {
        treasury = _treasury;
    }

    /// @notice Decrease the snacks per second
    function setSnacksPerSecond(uint256 _snacksPerSecond) public onlyOwner {
        if (_snacksPerSecond > 1e20) revert SnackShack_InflationTooHigh();
        snacksPerSecond = _snacksPerSecond;
    }

    /// @notice View function to see pending SNACK on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending SNACK reward for a given user.
    function pendingSnacks(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSnacksPerShare = pool.accSnacksPerShare;
        uint256 multiplier = _userMultiplier(user);

        if (block.timestamp > pool.lastRewardTimestamp && pool.totalSupply != 0) {
            uint256 elapsed = block.timestamp - pool.lastRewardTimestamp;
            uint256 snacksReward = elapsed * snacksPerSecond * pool.allocPoint / totalAllocPoint;
            accSnacksPerShare = accSnacksPerShare + snacksReward * ACC_SNACK_PRECISION / pool.totalSupply;
        }

        if (farmType[_pid] == FarmType.SCALED) {
            pending = uint256(
                int256(
                    user.amount * multiplier / ACC_SNACK_PRECISION * accSnacksPerShare / ACC_SNACK_PRECISION
                ) - user.rewardDebt
            );
        } else {
            pending = uint256(
                int256(
                    user.amount * accSnacksPerShare / ACC_SNACK_PRECISION
                ) - user.rewardDebt
            );
        }
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];

        if (block.timestamp > pool.lastRewardTimestamp) {
            if (pool.totalSupply > 0) {
                uint256 elapsed = block.timestamp - pool.lastRewardTimestamp;
                uint256 snacksReward = elapsed * snacksPerSecond * pool.allocPoint / totalAllocPoint;

                pool.accSnacksPerShare = pool.accSnacksPerShare + uint128(
                    snacksReward * ACC_SNACK_PRECISION / pool.totalSupply
                );

                if (farmType[pid] == FarmType.SCALED) {
                    SNACK.mint(treasury, snacksReward);
                    SNACK.mint(address(this), snacksReward * 10);
                } else {
                    SNACK.mint(treasury, snacksReward / 10);
                    SNACK.mint(address(this), snacksReward);
                }
            }

            pool.lastRewardTimestamp = uint64(block.timestamp);
            poolInfo[pid] = pool;

            emit LogUpdatePool(pid, pool.lastRewardTimestamp, pool.totalSupply, pool.accSnacksPerShare);
        }
    }

    // function 

    /// @notice Deposit LP tokens to earn SNACK allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(uint256 pid, uint256 amount, address to, bytes calldata data) public payable nonReentrant {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][to];

        // Effects
        user.amount = user.amount + amount;

        if (farmType[pid] == FarmType.SCALED) {
            uint256 multiplier = _userMultiplier(user);

            user.rewardDebt = user.rewardDebt + int256(
                amount * multiplier / ACC_SNACK_PRECISION * pool.accSnacksPerShare / ACC_SNACK_PRECISION
            );
            user.prevElapsed += user.depositTimestamp > 0 ? uint64(block.timestamp - user.depositTimestamp) : 1;
            user.depositTimestamp = uint64(block.timestamp);
        } else {
            user.rewardDebt = user.rewardDebt + int256(
                amount * pool.accSnacksPerShare / ACC_SNACK_PRECISION
            );
        }

        pool.totalSupply = pool.totalSupply + amount;
        poolInfo[pid] = pool;

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSnacksReward(pid, to, to, 0, user.amount);
        }

       _deposit(pid, amount, to, msg.sender, data);

        emit Deposit(msg.sender, pid, amount, to);
    }

    /// @notice Withdraw LP tokens from pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(uint256 pid, uint256 amount, address to, bytes calldata data) public nonReentrant {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        // Effects
        user.amount = user.amount - amount;

        if (farmType[pid] == FarmType.SCALED) {
            uint256 multiplier = _userMultiplier(user);
            
            user.rewardDebt = user.rewardDebt - int256(
                amount * multiplier / ACC_SNACK_PRECISION * pool.accSnacksPerShare / ACC_SNACK_PRECISION
            );
            user.prevElapsed += uint64(block.timestamp - user.depositTimestamp);
            user.depositTimestamp = uint64(block.timestamp);
        } else {
            user.rewardDebt = user.rewardDebt - int256(
                amount * pool.accSnacksPerShare / ACC_SNACK_PRECISION
            );
        }

        pool.totalSupply = pool.totalSupply - amount;
        poolInfo[pid] = pool;

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSnacksReward(pid, msg.sender, to, 0, user.amount);
        }

        _withdraw(pid, amount, to, msg.sender, data);

        emit Withdraw(msg.sender, pid, amount, to);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of SNACK rewards.
    function harvest(uint256 pid, address to) public nonReentrant {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 _pendingSnacks;

        // Effects
        if (farmType[pid] == FarmType.SCALED) {
            uint256 multiplier = _userMultiplier(user);
            int256 accumulatedSnacks = int256(
                user.amount * multiplier / ACC_SNACK_PRECISION * pool.accSnacksPerShare / ACC_SNACK_PRECISION
            );
            
            _pendingSnacks = uint256(accumulatedSnacks - user.rewardDebt);
            
            user.prevElapsed += uint64(block.timestamp - user.depositTimestamp);
            user.depositTimestamp = uint64(block.timestamp);
            user.rewardDebt = accumulatedSnacks;
        } else {
            int256 accumulatedSnacks = int256(
                user.amount * pool.accSnacksPerShare / ACC_SNACK_PRECISION
            );
            _pendingSnacks = uint256(accumulatedSnacks - user.rewardDebt);
            
            user.rewardDebt = accumulatedSnacks;
        }

        // Interactions
        if (_pendingSnacks != 0) {
            SNACK.safeTransfer(to, _pendingSnacks);
        }
        
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSnacksReward( pid, msg.sender, to, _pendingSnacks, user.amount);
        }

        emit Harvest(msg.sender, pid, _pendingSnacks);
    }
    
    /// @notice Withdraw LP tokens from pool and harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens and SNACK rewards.
    function withdrawAndHarvest(uint256 pid, uint256 amount, address to, bytes calldata data) public nonReentrant {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 _pendingSnacks;

        // Effects
        user.amount = user.amount - amount;

        if (farmType[pid] == FarmType.SCALED) {
            uint256 multiplier = _userMultiplier(user);
            int256 accumulatedSnacks = int256(
                user.amount * multiplier * ACC_SNACK_PRECISION * pool.accSnacksPerShare / ACC_SNACK_PRECISION
            );

            _pendingSnacks = uint256(accumulatedSnacks - user.rewardDebt);
            
            user.rewardDebt = accumulatedSnacks - int256(
                amount * multiplier / ACC_SNACK_PRECISION * pool.accSnacksPerShare / ACC_SNACK_PRECISION
            );
            user.prevElapsed += uint64(block.timestamp - user.depositTimestamp);
            user.depositTimestamp = uint64(block.timestamp);
        } else {
            int256 accumulatedSnacks = int256(
                user.amount * pool.accSnacksPerShare / ACC_SNACK_PRECISION
            );

            _pendingSnacks = uint256(accumulatedSnacks - user.rewardDebt);

            user.rewardDebt = accumulatedSnacks - int256(
                amount * pool.accSnacksPerShare / ACC_SNACK_PRECISION
            );
        }

        pool.totalSupply = pool.totalSupply - amount;
        poolInfo[pid] = pool;
        
        // Interactions
        SNACK.safeTransfer(to, _pendingSnacks);

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSnacksReward(pid, msg.sender, to, _pendingSnacks, user.amount);
        }

        _withdraw(pid, amount, to, msg.sender, data);

        emit Withdraw(msg.sender, pid, amount, to);
        emit Harvest(msg.sender, pid, _pendingSnacks);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pid, address to, bytes calldata data) public nonReentrant {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
       
        // Effects
        user.amount = 0;
        user.rewardDebt = 0;

        pool.totalSupply = pool.totalSupply - amount;
        poolInfo[pid] = pool;

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSnacksReward(pid, msg.sender, to, 0, 0);
        }

        if (amount > 0) {
            _withdraw(pid, amount, to, msg.sender, data);
        }

        emit EmergencyWithdraw(msg.sender, pid, amount, to);
    }

    function _deposit(
        uint256 pid,
        uint256 amount,
        address to,
        address from,
        bytes calldata data
    ) internal {
        IController _controller = controller[pid];
        
        bool success;
        
        try _controller.onDeposit(pid, poolToken[pid], amount, to, from, data) returns (bool _success) {
            success = _success;
        } catch (bytes memory err) {
            success = false;
            emit DepositFailed(abi.decode(err, (string)));
        }
        if (!success) revert SnackShack_FailedDepositCallback();
    }

    function _withdraw(
        uint256 pid,
        uint256 amount,
        address to,
        address from,
        bytes calldata data
    ) internal {
        IController _controller = controller[pid];
        
        bool success;
        
        try _controller.onWithdraw(pid, poolToken[pid], amount, to, from, data) returns (bool _success) {
            success = _success;
        } catch (bytes memory err) {
            success = false;
            emit WithdrawalFailed(abi.decode(err, (string)));
        }
        if (!success) revert SnackShack_FailedWithdrawCallback();
    }
}