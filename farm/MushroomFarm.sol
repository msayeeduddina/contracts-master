// File: masterchef.sol

pragma solidity 0.8.10;

import '@openzeppelin/contracts8/access/Ownable.sol';
import '@openzeppelin/contracts8/utils/math/SafeMath.sol';
import '@openzeppelin/contracts8/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts8/security/ReentrancyGuard.sol';

import './MushToken.sol';

contract MushroomFarm is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. Native to distribute per second.
        uint256 lastRewardSecond; // Last second that Native distribution occurs.
        uint256 accNativePerShare; // Accumulated Native per share, times 1e18. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
        uint256 lpSupply;
        bool isNative;
    }

    // The native token!
    MushToken public immutable native;
    // Dev address.
    address public devaddr;
    // Marketing address for giveaways and promotions
    address public marketingAddr;
    // Native tokens created per second.
    uint256 public nativePerSecond;
    // Deposit Fee address
    address public feeAddress;
    // Max emission rate.
    uint256 public constant MAX_EMISSION_RATE = 10 ether;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block timestamp when native mining starts.
    uint256 public startTime;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 nativePerSecond);
    event addPool(
        uint256 indexed pid,
        address lpToken,
        uint256 allocPoint,
        uint256 depositFeeBP
    );
    event setPool(
        uint256 indexed pid,
        address lpToken,
        uint256 allocPoint,
        uint256 depositFeeBP
    );
    event UpdateStartTime(uint256 newStartTime);

    constructor(
        MushToken _native,
        address _devaddr,
        address _marketingAddr,
        address _feeAddress,
        uint256 _NativePerSecond,
        uint256 _startTime
    ) {
        native = _native;
        devaddr = _devaddr;
        marketingAddr = _marketingAddr;
        feeAddress = _feeAddress;
        nativePerSecond = _NativePerSecond;
        startTime = _startTime;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, 'nonDuplicated: duplicated');
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        bool _isNative,
        bool _withUpdate
    ) public onlyOwner nonDuplicated(_lpToken) {
        // valid ERC20 token
        _lpToken.balanceOf(address(this));

        require(_depositFeeBP <= 400, 'add: invalid deposit fee basis points');
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardSecond = block.timestamp > startTime
            ? block.timestamp
            : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardSecond: lastRewardSecond,
                accNativePerShare: 0,
                depositFeeBP: _depositFeeBP,
                lpSupply: 0,
                isNative: _isNative
            })
        );

        emit addPool(
            poolInfo.length - 1,
            address(_lpToken),
            _allocPoint,
            _depositFeeBP
        );
    }

    // Update the given pool's native allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) external onlyOwner {
        require(_depositFeeBP <= 400, 'set: invalid deposit fee basis points');
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;

        emit setPool(
            _pid,
            address(poolInfo[_pid].lpToken),
            _allocPoint,
            _depositFeeBP
        );
    }

    // Sets the deposit fee of all non natives in the farm.
    function setGlobalDepositFee(uint16 _globalDepositFeeBP)
        external
        onlyOwner
    {
        require(
            _globalDepositFeeBP <= 400,
            'set: invalid deposit fee basis points'
        );

        for (uint256 pid = 0; pid < poolInfo.length; ++pid) {
            if (poolInfo[pid].isNative == false) {
                updatePool(pid);
                poolInfo[pid].depositFeeBP = _globalDepositFeeBP;

                emit setPool(
                    pid,
                    address(poolInfo[pid].lpToken),
                    poolInfo[pid].allocPoint,
                    _globalDepositFeeBP
                );
            }
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        pure
        returns (uint256)
    {
        return _to.sub(_from);
    }

    // View function to see pending native on frontend.
    function pendingNative(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accNativePerShare = pool.accNativePerShare;
        if (
            block.timestamp > pool.lastRewardSecond &&
            pool.lpSupply != 0 &&
            totalAllocPoint > 0
        ) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardSecond,
                block.timestamp
            );
            uint256 nativeReward = multiplier
                .mul(nativePerSecond)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            uint256 devReward = nativeReward.div(10);
            uint256 totalRewards = native.totalSupply().add(devReward).add(
                nativeReward
            );
            if (totalRewards > native.cap()) {
                nativeReward = native.cap().sub(native.totalSupply());
            }
            accNativePerShare = accNativePerShare.add(
                nativeReward.mul(1e18).div(pool.lpSupply)
            );
        }
        return
            user.amount.mul(accNativePerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardSecond) {
            return;
        }
        if (pool.lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardSecond = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(
            pool.lastRewardSecond,
            block.timestamp
        );
        uint256 nativeReward = multiplier
            .mul(nativePerSecond)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);

        uint256 devReward = nativeReward.div(10);
        uint256 marketingReward = nativeReward.div(50);
        uint256 totalRewards = native
            .totalSupply()
            .add(devReward)
            .add(nativeReward)
            .add(marketingReward);

        if (totalRewards <= native.cap()) {
            // mint as normal as not at maxSupply
            native.mint(devaddr, nativeReward.div(10));
            native.mint(marketingAddr, nativeReward.div(50));
            native.mint(address(this), nativeReward);
        } else {
            // mint the difference only to MC, update nativeReward
            nativeReward = native.cap().sub(native.totalSupply());
            native.mint(address(this), nativeReward);
        }

        if (nativeReward != 0) {
            // only calculate and update if nativeReward is non 0
            pool.accNativePerShare = pool.accNativePerShare.add(
                nativeReward.mul(1e18).div(pool.lpSupply)
            );
        }

        pool.lastRewardSecond = block.timestamp;
    }

    // Deposit LP tokens to MasterChef for native allocation.
    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.accNativePerShare)
                .div(1e18)
                .sub(user.rewardDebt);
            if (pending > 0) {
                safeNativeTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            _amount = pool.lpToken.balanceOf(address(this)).sub(balanceBefore);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpSupply = pool.lpSupply.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
                pool.lpSupply = pool.lpSupply.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accNativePerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, 'withdraw: not good');
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accNativePerShare).div(1e18).sub(
            user.rewardDebt
        );
        if (pending > 0) {
            safeNativeTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            pool.lpSupply = pool.lpSupply.sub(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accNativePerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);

        if (pool.lpSupply >= amount) {
            pool.lpSupply = pool.lpSupply.sub(amount);
        } else {
            pool.lpSupply = 0;
        }

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe native transfer function, just in case if rounding error causes pool to not have enough coins.
    function safeNativeTransfer(address _to, uint256 _amount) internal {
        uint256 starBal = native.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > starBal) {
            transferSuccess = native.transfer(_to, starBal);
        } else {
            transferSuccess = native.transfer(_to, _amount);
        }
        require(transferSuccess, 'safeNativeTransfer: transfer failed');
    }

    // Update dev address.
    function setDevAddress(address _devaddr) external {
        require(_devaddr != address(0), '!nonzero');
        require(msg.sender == devaddr, 'dev: wut?');
        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    function setFeeAddress(address _feeAddress) external {
        require(msg.sender == feeAddress, 'setFeeAddress: FORBIDDEN');
        require(_feeAddress != address(0), '!nonzero');
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _NativePerSecond) external onlyOwner {
        require(_NativePerSecond <= MAX_EMISSION_RATE, 'Emission too high');
        massUpdatePools();
        nativePerSecond = _NativePerSecond;
        emit UpdateEmissionRate(msg.sender, _NativePerSecond);
    }

    // Only update before start of farm
    function updateStartTime(uint256 _newStartTime) external onlyOwner {
        require(
            block.timestamp < startTime,
            'cannot change start time if farm has already started'
        );
        require(
            block.timestamp < _newStartTime,
            'cannot set start time in the past'
        );
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardSecond = _newStartTime;
        }
        startTime = _newStartTime;

        emit UpdateStartTime(startTime);
    }
}
