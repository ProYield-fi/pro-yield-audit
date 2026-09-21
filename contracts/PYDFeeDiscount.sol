// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PYDFeeDiscount — stake PYD, get your share of the fee pool back
/// @notice The PYD utility sink: tiered fee rebates mirroring Hyperliquid's
/// HYPE staking discount model, adapted to a vault with COLLECTIVE fees.
///
/// WHY A REBATE (not an execution-time discount): ProYieldVault charges the
/// performance fee on total profit and attributes NET profit pro-rata (one
/// share price, audited surface). A per-user execution-time discount would
/// require per-user share prices — a non-starter. The rebate delivers the
/// same demand driver (stake PYD → save on bigger fees) without touching the
/// vault: fees land in FeeDistributor as today, and this contract returns
/// each staker's share of them, tiered by their PYD stake.
///
/// HONEST ACCOUNTING (repo discipline):
/// - Staked PYD is NEVER yield — it is the utility position that sets your tier.
/// - Rebates accrue ONLY from real fee deltas: `snapshotHarvest()` reads the
///   USDC balance of FeeDistributor itself (public read, trust-minimized) and
///   accrues the delta since the last snapshot — no keeper-supplied numbers.
/// - Claimable rebates can never exceed the USDC budget actually routed in —
///   claim() pays what exists, keeps the remainder accrued (never fake).
/// - Stakers with zero vault shares (withdrew everything, kept the stake)
///   accrue nothing — no deposits, no fees paid, no rebate. Fair by design.
///
/// DEMAND MODEL (legal posture): a DISCOUNT on fees the user already pays —
/// not a return promise. Tiers are owner-settable; MAX_TIER_BPS hard cap.
contract PYDFeeDiscount is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable pyd;      // the utility/stake token
    IERC20 public immutable usdc;     // the rebate currency (vault fee currency)
    address public immutable feeDistributor; // where vault fees land (read-only)
    address public immutable vault;          // share weights are read from here

    /// @notice Tier schedule: [stakeThreshold, discountBps] pairs.
    /// A staker's tier = the HIGHEST threshold their stake crosses.
    uint256[][] public tiers;
    uint256 public constant MAX_TIER_BPS = 4000; // hard cap: 40% of the fee

    /*//////////////////////// Accounting ////////////////////////*/
    uint256 public lastFeeSnapshot;   // FD USDC balance at the last snapshot
    uint256 public lastSnapshotAt;
    mapping(address => uint256) public rebateOf;  // accrued-but-unclaimed (USDC 6dp)
    mapping(address => uint256) public stakedBy;  // per-user stake ledger
    address[] public stakerList;
    mapping(address => bool) public isStaker;

    /*//////////////////////// Custom errors ////////////////////////*/
    error PYDFee__ZeroAmount();
    error PYDFee__ExceedsStake();
    error PYDFee__BadTier();
    error PYDFee__NothingAccrued();
    error PYDFee__InsufficientBudget();
    error PYDFee__ZeroAddresses();

    /*//////////////////////// Events ////////////////////////*/
    event Staked(address indexed user, uint256 amount, uint256 tierBps);
    event Unstaked(address indexed user, uint256 amount);
    event SnapshotHarvested(uint256 feeDelta, uint256 totalShares, uint256 stakersAccrued);
    event RebateClaimed(address indexed user, uint256 amount);
    event TiersSet(uint256[][] tiers);
    event BudgetReceived(uint256 totalBudget);

    constructor(address _pyd, address _usdc, address _feeDistributor, address _vault, address initialOwner)
        Ownable(initialOwner)
    {
        if (_pyd == address(0) || _usdc == address(0) || _feeDistributor == address(0) || _vault == address(0)) {
            revert PYDFee__ZeroAddresses();
        }
        pyd = IERC20(_pyd);
        usdc = IERC20(_usdc);
        feeDistributor = _feeDistributor;
        vault = _vault;
        // Default tiers (mirroring HL HYPE staking, scaled for PYD):
        // ≥1,000 = 5% · ≥10K = 10% · ≥100K = 15% · ≥1M = 20% (of the fee).
        tiers = new uint256[][](4);
        tiers[0] = _tier(1_000e18, 500);
        tiers[1] = _tier(10_000e18, 1000);
        tiers[2] = _tier(100_000e18, 1500);
        tiers[3] = _tier(1_000_000e18, 2000);
    }

    function _tier(uint256 threshold, uint256 bps) internal pure returns (uint256[] memory) {
        uint256[] memory t = new uint256[](2);
        t[0] = threshold;
        t[1] = bps;
        return t;
    }

    /*//////////////////////// Admin ////////////////////////*/
    /// @dev Replace the tier schedule. Validates: strictly ascending
    /// thresholds, bps cap.
    function setTiers(uint256[][] calldata newTiers) external onlyOwner {
        if (newTiers.length == 0) revert PYDFee__BadTier();
        uint256 prevThreshold = 0;
        for (uint256 i = 0; i < newTiers.length; i++) {
            if (newTiers[i][0] <= prevThreshold) revert PYDFee__BadTier(); // must ascend
            if (newTiers[i][1] > MAX_TIER_BPS) revert PYDFee__BadTier();
            prevThreshold = newTiers[i][0];
        }
        delete tiers;
        uint256 len = newTiers.length;
        for (uint256 i = 0; i < len; i++) {
            tiers.push(newTiers[i]);
        }
        emit TiersSet(newTiers);
    }

    /*//////////////////////// Staker actions ////////////////////////*/
    /// @notice Stake PYD to raise your discount tier. Stake is NEVER yield —
    /// it only sets the tier; rebates come from real fee deltas.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert PYDFee__ZeroAmount();
        pyd.safeTransferFrom(msg.sender, address(this), amount);
        stakedBy[msg.sender] += amount;
        if (!isStaker[msg.sender]) {
            isStaker[msg.sender] = true;
            stakerList.push(msg.sender);
        }
        emit Staked(msg.sender, amount, tierBpsOf(msg.sender));
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert PYDFee__ZeroAmount();
        if (amount > stakedBy[msg.sender]) revert PYDFee__ExceedsStake();
        stakedBy[msg.sender] -= amount;
        pyd.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Full exit: unstake everything. Accrued rebates remain claimable.
    function exit() external nonReentrant {
        uint256 staked = stakedBy[msg.sender];
        if (staked > 0) {
            stakedBy[msg.sender] = 0;
            pyd.safeTransfer(msg.sender, staked);
            emit Unstaked(msg.sender, staked);
        }
        // NOTE: stays in stakerList (zero-stake entries simply accrue 0).
    }

    /// @notice Discount tier (bps of the fee) for a staker's current stake.
    function tierBpsOf(address user) public view returns (uint256) {
        uint256 staked = stakedBy[user];
        uint256 best = 0;
        uint256 len = tiers.length;
        for (uint256 i = 0; i < len; i++) {
            if (staked >= tiers[i][0] && tiers[i][1] > best) {
                best = tiers[i][1];
            }
        }
        return best;
    }

    /*//////////////////////// Snapshot accrual (permissionless) ////////////////////////*/
    /// @notice Accrue rebates from REAL fee deltas. Permissionless: reads
    /// FeeDistributor's USDC balance and the vault's share weights itself —
    /// the caller supplies nothing. Call after each vault harvest (the keeper
    /// loop does this); calling again with no new fees is a clean no-op.
    ///
    /// rebate_i = (shares_i / totalShares) × feeDelta × tierBps_i / 10000
    /// — the staker's pro-rata share of the fee pool, scaled by their tier.
    function snapshotHarvest() external nonReentrant {
        uint256 fdBal = usdc.balanceOf(feeDistributor);
        if (fdBal <= lastFeeSnapshot) {
            // No new fees since the last snapshot — clean no-op (timestamp
            // still recorded so staleness is visible).
            lastSnapshotAt = block.timestamp;
            return;
        }
        uint256 feeDelta = fdBal - lastFeeSnapshot;
        lastFeeSnapshot = fdBal;
        lastSnapshotAt = block.timestamp;

        uint256 totalShares = _vaultTotalShares();
        if (totalShares == 0) {
            emit SnapshotHarvested(feeDelta, 0, 0);
            return;
        }

        uint256 len = stakerList.length;
        uint256 accrued = 0;
        for (uint256 i = 0; i < len; i++) {  // calls-loop: staker list only, bounded
            address staker = stakerList[i];
            uint256 shares_i = _vaultSharesOf(staker);
            if (shares_i == 0) continue; // no deposits → no fees paid → no rebate
            uint256 tierBps = tierBpsOf(staker);
            if (tierBps == 0) continue;  // staking below the first tier
            uint256 rebate = (shares_i * feeDelta * tierBps) / (totalShares * 10000);
            if (rebate > 0) {
                rebateOf[staker] += rebate;
                accrued++;
            }
        }
        emit SnapshotHarvested(feeDelta, totalShares, accrued);
    }

    /*//////////////////////// Claims ////////////////////////*/
    /// @notice Claim accrued rebates in USDC. Bounded by the budget actually
    /// routed in — never more claimable than real assets sit here.
    function claimRebate() external nonReentrant {
        uint256 amount = rebateOf[msg.sender];
        if (amount == 0) revert PYDFee__NothingAccrued();
        uint256 budget = usdc.balanceOf(address(this));
        if (amount > budget) {
            // Budget shortfall: pay what exists, keep the remainder accrued.
            amount = budget;
        }
        if (amount == 0) revert PYDFee__InsufficientBudget();
        rebateOf[msg.sender] -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit RebateClaimed(msg.sender, amount);
    }

    /// @notice Reconcile budget accounting after a plain USDC transfer (the
    /// recycler routes the discount budget here). Anyone may call.
    function receiveBudget() external {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) emit BudgetReceived(bal);
    }

    /*//////////////////////// Reads (vault shares via staticcall) ////////////////////////*/
    function _vaultTotalShares() internal view returns (uint256) {
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeWithSignature("totalShares()"));
        if (!ok) return 0;
        return abi.decode(ret, (uint256));
    }

    function _vaultSharesOf(address user) internal view returns (uint256) {
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeWithSignature("shares(address)", user));
        if (!ok) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @notice Accrued-but-unclaimed rebate for a staker.
    function harvestableRebate(address user) external view returns (uint256) {
        return rebateOf[user];
    }

    /// @notice Staker count (for keeper/ops visibility).
    function stakerCount() external view returns (uint256) {
        return stakerList.length;
    }
}
