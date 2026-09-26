// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal Morpho Blue interface (immutable core contract, deployed
/// per-chain; HyperEVM core = 0x68e37dE8d93d3496ae143F2E900490f6280C57cD).
interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);

    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

/// @notice Morpho Blue supply strategy — the REAL lending adapter (replaces
/// the principal-parking stub). Principal is supplied into ONE immutable
/// market chosen at deploy time; yield accrues in the position and is swept
/// to the vault as real USDC by the vault's harvest().
///
/// Accounting model: harvest sweeps `totalAssets() - lastHarvestAssets` (the
/// delta since the last sweep). Exact for pure lending accrual, and robust to
/// recalls because recall() subtracts the amount sent back from the baseline —
/// principal can never be booked as profit (the audit-09-20 drain vector).
///
/// Safety model:
///  - Funds only ever move to Morpho (supply) or the vault (recall/sweep).
///  - recall() is vault-only and unwinds the position synchronously; partial
///    is fine (capped by position + market liquidity), the vault measures what
///    actually arrived.
///  - The market (loanToken/collateral/oracle/irm/lltv) is immutable — no
///    caller-supplied markets, no phishing-market vector.
contract MorphoStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IMorpho public immutable morpho;
    bytes32 public immutable marketId;
    address public immutable collateralToken;
    address public immutable oracle;
    address public immutable irm;
    uint256 public immutable lltv;

    uint256 public bufferBps; // idle cushion kept back from supply() (recall gas)
    uint256 public lastHarvestPosition; // positionValue() baseline after last sweep/supply/recall
    uint256 public totalSupplied; // lifetime supplied (stats only)

    event Supplied(uint256 amount, uint256 shares);
    event Recalled(uint256 requested, uint256 returned);
    event BufferSet(uint256 bps);

    constructor(
        address _underlying,
        address initialOwner,
        address _morpho,
        address _collateralToken,
        address _oracle,
        address _irm,
        uint256 _lltv
    ) BaseStrategy(_underlying, initialOwner, "Morpho") {
        require(
            _morpho != address(0) && _collateralToken != address(0) && _oracle != address(0) && _irm != address(0),
            "Morpho: zero addr"
        );
        require(_lltv > 0 && _lltv < 1e18, "Morpho: bad lltv");
        morpho = IMorpho(_morpho);
        collateralToken = _collateralToken;
        oracle = _oracle;
        irm = _irm;
        lltv = _lltv;
        marketId = keccak256(abi.encode(_underlying, _collateralToken, _oracle, _irm, _lltv));
    }

    function name() external view override returns (string memory) {
        return "Morpho";
    }

    function _marketParams() internal view returns (IMorpho.MarketParams memory) {
        return IMorpho.MarketParams({
            loanToken: address(underlying),
            collateralToken: collateralToken,
            oracle: oracle,
            irm: irm,
            lltv: lltv
        });
    }

    /// @notice Value of the supplied position in underlying units (rounds DOWN).
    function positionValue() public view returns (uint256) {
        (uint256 shares,,) = morpho.position(marketId, address(this));
        if (shares == 0) return 0;
        (uint128 tsa, uint128 tss,,,,) = morpho.market(marketId);
        if (tss == 0) return 0;
        return (shares * tsa) / tss;
    }

    function totalAssets() public view override returns (uint256) {
        return underlying.balanceOf(address(this)) + positionValue();
    }

    /// @notice Keeper/owner: supply idle balance (above the buffer) into the market.
    function deploy() external nonReentrant {
        require(msg.sender == owner() || msg.sender == keeper, "Morpho: not keeper");
        require(isActive, "Morpho: inactive");
        uint256 bal = underlying.balanceOf(address(this));
        uint256 buffer = (bal * bufferBps) / 10000;
        uint256 amount = bal > buffer ? bal - buffer : 0;
        require(amount > 0, "Morpho: nothing to supply");
        underlying.forceApprove(address(morpho), amount);
        (, uint256 shares) = morpho.supply(_marketParams(), amount, 0, address(this), "");
        totalSupplied += amount;
        lastHarvestPosition = positionValue(); // new principal is never yield
        emit Supplied(amount, shares);
    }

    /// @notice Vault-only: return funds, unwinding the Morpho position as
    /// needed. Never reverts for market illiquidity — partial is fine, the
    /// vault measures what actually arrived (see _recallShortfall).
    function recall(uint256 amount) external override nonReentrant {
        require(msg.sender == vault, "Morpho: not vault");
        if (amount == 0) return;
        uint256 idle = underlying.balanceOf(address(this));
        if (idle < amount) {
            uint256 need = amount - idle;
            uint256 pv = positionValue();
            if (need > pv) need = pv;
            if (need > 0) _unwind(need);
        }
        uint256 bal = underlying.balanceOf(address(this));
        uint256 sent = amount > bal ? bal : amount;
        if (sent > 0) {
            // Re-baseline on the remaining position: principal leaving must
            // never later read as "negative yield" or as profit.
            lastHarvestPosition = positionValue();
            underlying.safeTransfer(vault, sent);
        }
        emit Recalled(amount, sent);
    }

    /// @dev Withdraw `need`-worth of assets from the market (by shares, ceil,
    /// capped by the position). try/catch: an illiquid market = partial no-op.
    function _unwind(uint256 need) internal {
        (uint256 shares,,) = morpho.position(marketId, address(this));
        (uint128 tsa, uint128 tss,,,,) = morpho.market(marketId);
        if (shares == 0 || tss == 0) return;
        uint256 sharesOut = (need * tss + tsa - 1) / tsa; // ceil
        if (sharesOut > shares) sharesOut = shares;
        try morpho.withdraw(_marketParams(), 0, sharesOut, address(this), address(this)) {} catch {}
    }

    /// @notice Vault-only: sweep accrued yield to the vault as real USDC.
    /// Yield = the POSITION's growth since the last baseline (deploy/recall/
    /// sweep all re-baseline). Idle arrivals — new vault allocations not yet
    /// deployed — are principal by construction and can never read as profit.
    function _doHarvest() internal override returns (uint256 profit) {
        if (!isActive) revert("Morpho: inactive");
        if (msg.sender != vault) return 0; // keeper/owner calls just no-op
        uint256 pv = positionValue();
        if (pv <= lastHarvestPosition) {
            lastHarvestPosition = pv; // re-baseline (market loss / post-recall edge)
            return 0;
        }
        uint256 accrued = pv - lastHarvestPosition;
        uint256 bal = underlying.balanceOf(address(this));
        if (bal < accrued) {
            _unwind(accrued - bal);
            bal = underlying.balanceOf(address(this));
        }
        uint256 buffer = (totalAssets() * bufferBps) / 10000;
        uint256 sweepable = bal > buffer ? bal - buffer : 0;
        uint256 sweep = accrued < sweepable ? accrued : sweepable;
        if (sweep == 0) return 0; // leave the baseline: yield stays claimable next sweep
        lastHarvestPosition = positionValue();
        underlying.safeTransfer(vault, sweep);
        return sweep; // BaseStrategy.harvest books it via totalDebt
    }

    function setBufferBps(uint256 bufferBps_) external onlyOwner nonReentrant {
        require(bufferBps_ <= 5000, "Morpho: buffer too high");
        bufferBps = bufferBps_;
        emit BufferSet(bufferBps_);
    }
}
