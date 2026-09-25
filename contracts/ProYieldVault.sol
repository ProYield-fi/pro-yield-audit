// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ProYieldVault is BaseStrategy {
    using SafeERC20 for IERC20;
    uint256 public performanceFee;
    uint256 public immutable withdrawalFee;
    uint256 public constant RESERVE_BPS = 1000; // 10% of assets kept liquid for withdrawals
    address public immutable feeDistributor;
    mapping(address => bool) public strategies;
    event PerformanceFeeSet(uint256 fee);
    mapping(address => bool) public strategyActive;   // per-strategy circuit breaker
    event StrategyHarvestFailed(address indexed strategy);
    // ── Beta safety rails (S2 unlock plan): hard limits live in code, not policy.
    // Caps are owner-set; 0 = uncapped. The pause blocks NEW deposits only —
    // withdrawals always stay open so users are never trapped.
    uint256 public tvlCap;         // max totalAssets() in asset units
    uint256 public perUserCap;     // max per-user VALUE in asset units (value, not principal)
    bool public depositsPaused;
    event CapsSet(uint256 tvlCap, uint256 perUserCap);
    event DepositsPausedSet(bool paused);
    uint256 private _totalAssets;
    uint256 private _totalShares;                     // sum of all user shares (ERC-4626 style)
    address[] public strategyList;
    // Virtual share offset (OpenZeppelin ERC4626 pattern): blunts first-depositor
    // inflation attacks by requiring huge donations to move the share price.
    uint256 private constant SHARE_OFFSET = 1e3;

    constructor(
        address _underlying,
        address initialOwner,
        address _feeDistributor
    ) BaseStrategy(_underlying, initialOwner, "ProYieldVault") {
        require(_feeDistributor != address(0), "ProYieldVault: zero feeDistributor");
        require(_underlying != address(0), "ProYieldVault: zero underlying");
        require(initialOwner != address(0), "ProYieldVault: zero owner");
        feeDistributor = _feeDistributor;
        performanceFee = 1000;
        withdrawalFee = 0; // product promise: NO withdrawal fees (kept for future gating)
    }

    function name() external view override returns (string memory) {
        return "ProYieldVault";
    }

    function totalAssets() public override view returns (uint256) {
        return _totalAssets;
    }

    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    /// Shares for a given asset amount at the current price (floor).
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _toShares(assets);
    }

    /// Asset value of a share amount at the current price (floor).
    function convertToAssets(uint256 sharesAmt) external view returns (uint256) {
        return _toAssets(sharesAmt); // named sharesAmt — does not shadow BaseStrategy.shares
    }

    /// Max assets `account` can withdraw right now (frontend helper).
    function maxWithdraw(address account) external view returns (uint256) {
        return _toAssets(shares[account]);
    }

    function _toShares(uint256 assets) internal view returns (uint256) {
        if (_totalShares == 0) return assets; // first depositor: 1:1
        return (assets * (_totalShares + SHARE_OFFSET)) / (_totalAssets + SHARE_OFFSET);
    }

    function _toAssets(uint256 sharesAmt) internal view returns (uint256) {
        if (_totalShares == 0) return sharesAmt;
        return (sharesAmt * (_totalAssets + SHARE_OFFSET)) / (_totalShares + SHARE_OFFSET);
    }

    function addStrategy(address strategy) external onlyOwner {
        require(strategy != address(0), "ProYieldVault: zero strategy");
        strategies[strategy] = true;
        strategyActive[strategy] = true;   // new strategies start active
        strategyList.push(strategy);
    }

    /// @notice Quarantine one strategy without stopping the whole vault.
    /// Inactive strategies are skipped by allocate() and cannot be harvested into.
    function setStrategyActive(address strategy, bool active) external onlyOwner {
        require(strategies[strategy], "ProYieldVault: not a strategy");
        strategyActive[strategy] = active;
    }

    /// @notice Set the beta safety rails. 0 = uncapped; takes effect immediately.
    function setCaps(uint256 _tvlCap, uint256 _perUserCap) external onlyOwner {
        tvlCap = _tvlCap;
        perUserCap = _perUserCap;
        emit CapsSet(_tvlCap, _perUserCap);
    }

    /// @notice Pause/unpause NEW deposits (withdrawals stay open by design).
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    function deposit(uint256 amount) external override nonReentrant {
        require(!depositsPaused, "ProYieldVault: deposits paused");
        require(amount > 0, "ProYieldVault: zero amount");
        if (tvlCap > 0) {
            require(_totalAssets + amount <= tvlCap, "ProYieldVault: TVL cap reached");
        }
        if (perUserCap > 0) {
            require(_toAssets(shares[msg.sender]) + amount <= perUserCap, "ProYieldVault: per-user cap reached");
        }
        uint256 sh = _toShares(amount); // price-aware mint (4626-style)
        require(sh > 0, "ProYieldVault: zero shares"); // dust guard — no free deposits
        shares[msg.sender] += sh;
        _totalShares += sh;
        _totalAssets += amount;
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    function setPerformanceFee(uint256 fee) external onlyOwner {
        require(fee <= 10000, "ProYieldVault: fee too high");
        performanceFee = fee;
        emit PerformanceFeeSet(fee);
    }

    function emergencyWithdraw() external onlyOwner nonReentrant {
        uint256 balance = underlying.balanceOf(address(this));
        if (balance == 0) return;
        underlying.safeTransfer(msg.sender, balance);
        // Keep liabilities in sync: assets leaving the vault must shrink
        // totalAssets or depositor claims exceed real backing (T-012 follow-up).
        _totalAssets -= balance;
    }

    event LossReported(uint256 amount);

    /// @notice Write booked liabilities down to match REAL backing after a
    /// strategy/venue loss (round-2 H1). Owner-only (beta owner = treasury
    /// Safe): the loss is measured from live venue reads off-chain, then
    /// reported here so the remaining depositors socialise it pro-rata
    /// (share price falls for everyone) instead of the books carrying phantom
    /// value while withdrawals revert. Without this call a loss is invisible;
    /// with it, claims always reconcile to what actually backs them.
    function reportLoss(uint256 amount) external onlyOwner {
        require(amount <= _totalAssets, "ProYieldVault: exceeds assets");
        _totalAssets -= amount;
        emit LossReported(amount);
    }

    function allocate() external onlyOwner nonReentrant {
        uint256 balance = underlying.balanceOf(address(this));
        // Keep a liquid reserve so withdrawals never depend on strategy recall.
        uint256 reserve = (_totalAssets * RESERVE_BPS) / 10000;
        uint256 deployable = balance > reserve ? balance - reserve : 0;
        if (deployable > 0 && strategyList.length > 0) {
            // Split only across ACTIVE strategies; inactive ones get nothing.
            uint256 activeCount = 0;
            for (uint i = 0; i < strategyList.length; i++) {
                if (strategies[strategyList[i]] && strategyActive[strategyList[i]]) {
                    activeCount++;
                }
            }
            if (activeCount == 0) return;
            uint256 perStrategy = deployable / activeCount;
            for (uint i = 0; i < strategyList.length; i++) {
                address strategy = strategyList[i];
                if (strategies[strategy] && strategyActive[strategy] && perStrategy > 0) {
                    underlying.safeTransfer(strategy, perStrategy);
                }
            }
        }
    }

    /// @notice Pull funds back from strategies until `needed` is idle.
    /// Splits the shortfall across active strategies; recall is capped at each
    /// strategy's balance, so a shortfall larger than total recalled reverts
    /// downstream (correct behavior — cannot pay out assets that don't exist).
    function _recallShortfall(uint256 needed) internal {
        uint256 idle = underlying.balanceOf(address(this));
        if (idle >= needed) return;
        uint256 missing = needed - idle;
        uint256 activeCount = 0;
        for (uint i = 0; i < strategyList.length; i++) {
            if (strategies[strategyList[i]] && strategyActive[strategyList[i]]) {
                activeCount++;
            }
        }
        if (activeCount == 0) return; // withdraw will revert on insufficient idle
        uint256 perStrategy = (missing / activeCount) + 1; // round up
        for (uint i = 0; i < strategyList.length && missing > 0; i++) {
            address strategy = strategyList[i];
            if (strategies[strategy] && strategyActive[strategy]) {
                BaseStrategy(strategy).recall(perStrategy);
                uint256 got = underlying.balanceOf(address(this)) - idle;
                idle += got;
                missing = got >= missing ? 0 : missing - got;
            }
        }
    }

    /// @notice User withdrawal by ASSET amount. Shares burned are computed at
    /// the current price (4626-style): when the vault has earned profit, a
    /// user's shares redeem for MORE than they deposited.
    /// Pays from idle; recalls from strategies to cover any shortfall.
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "ProYieldVault: zero amount");
        require(amount <= totalAssets(), "ProYieldVault: exceeds assets");
        uint256 sh = _toShares(amount);
        require(sh > 0, "ProYieldVault: zero shares");
        require(sh <= shares[msg.sender], "ProYieldVault: exceeds shares");
        // Effects BEFORE interactions (slither reentrancy-no-eth): burn shares
        // and shrink liabilities before any external recall call.
        shares[msg.sender] -= sh;
        _totalShares -= sh;
        _totalAssets -= amount;
        _recallShortfall(amount);
        underlying.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    /// @notice Partial-redemption escape hatch (round-2 H1): withdraw as much
    /// as idle + recallable balance can ACTUALLY pay right now. Never reverts
    /// for illiquidity alone; shares burn only for what is paid, so the rest
    /// of the claim stays on the books. Under a reported loss the price is
    /// already written down and this pays the fair amount; under an
    /// unreported loss it still lets users exit with the real backing that
    /// exists instead of being fully trapped by phantom value.
    function withdrawUpTo(uint256 amount) external nonReentrant returns (uint256 paid) {
        require(amount > 0, "ProYieldVault: zero amount");
        uint256 want = _toAssets(shares[msg.sender]);
        if (amount < want) want = amount;
        require(want > 0, "ProYieldVault: zero shares");
        _recallShortfall(want);
        uint256 bal = underlying.balanceOf(address(this));
        paid = bal < want ? bal : want;
        require(paid > 0, "ProYieldVault: no liquidity");
        uint256 sh = _toShares(paid);
        if (sh > shares[msg.sender]) sh = shares[msg.sender];
        shares[msg.sender] -= sh;
        _totalShares -= sh;
        _totalAssets -= paid;
        underlying.safeTransfer(msg.sender, paid);
        emit Withdraw(msg.sender, paid);
    }

    function harvest() external override nonReentrant {
        // Sweep accrued profit from every active strategy, then take the
        // performance fee on what actually landed (no modeled yield).
        uint256 idleBefore = underlying.balanceOf(address(this));
        uint256 len = strategyList.length;
        for (uint256 i = 0; i < len; i++) {  // calls-loop: vault-authorized strategies only
            address s = strategyList[i];
            if (strategies[s] && strategyActive[s]) {
                // Resilient sweep: ONE broken strategy must never brick the
                // whole vault's harvest (profits of healthy strategies would
                // strand, keeper loops, fee loop stalls). Skip + emit; the
                // strategy stays visible for ops/owner intervention.
                try BaseStrategy(s).harvest() {
                } catch {
                    emit StrategyHarvestFailed(s);
                }
            }
        }
        uint256 totalProfit = underlying.balanceOf(address(this)) - idleBefore;
        if (totalProfit > 0 && performanceFee > 0) {
            uint256 fee = (totalProfit * performanceFee) / 10000;
            if (fee > 0) underlying.safeTransfer(feeDistributor, fee);
        }
        // Profit attribution (4626-style): NET profit (after fee) raises the
        // share price — every depositor earns pro-rata. Fees leave accounting.
        if (totalProfit > _feeOn(totalProfit)) {
            _totalAssets += totalProfit - _feeOn(totalProfit);
        }
        lastHarvest = block.timestamp;
        emit Harvest(totalProfit);
    }

    /// Fee mirror of harvest's calculation (internal, avoids duplication).
    function _feeOn(uint256 profit) internal view returns (uint256) {
        if (performanceFee == 0) return 0;
        return (profit * performanceFee) / 10000;
    }

    /// @notice Credit EXTERNAL yield (fee recycling, rebates, grants) to
    /// depositors by raising the share price. Flow: the recycler routes X
    /// USDC into this vault (FeeDistributor.route), then calls creditYield(X).
    /// The balance check makes crediting more than actually sits in the vault
    /// impossible; the recycler's route+credit pairing keeps accounting ==
    /// real assets (credit only NEW arrivals, never re-count idle).
    event YieldCredited(uint256 amount);

    function creditYield(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "ProYieldVault: zero amount");
        require(underlying.balanceOf(address(this)) >= amount, "ProYieldVault: exceeds balance");
        _totalAssets += amount;
        emit YieldCredited(amount);
    }

    function harvestStrategy(address strategy) external onlyOwner nonReentrant {
        require(strategies[strategy], "ProYieldVault: not a strategy");
        require(strategyActive[strategy], "ProYieldVault: strategy paused");
        require(strategy != address(0), "ProYieldVault: zero strategy");
        BaseStrategy(strategy).harvest();
    }
}
