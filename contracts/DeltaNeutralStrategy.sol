// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFundingOracle} from "./mocks/MockFundingOracle.sol";

contract DeltaNeutralStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    address public shortPosition;
    uint256 public delta;              // open position size (USDC notional)
    uint256 public fundingRate;        // last fetched annualized bps
    uint256 public lastUpdate;         // last funding fetch
    uint256 public lastAccrual;        // last funding accrual timestamp
    uint256 public accruedFunding;     // cumulative funding earned, un-swept (USDC)
    uint256 public totalPrincipal;     // USDC-notional opened across positions
    mapping(address => uint256) public positions;
    address public oracle;             // IFundingOracle — annualized bps
    address public fundingSource;      // venue settlement payer (testnet: MockFundingSource)

    uint256 public constant BPS_DENOM = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    event PositionOpened(address indexed user, uint256 size);
    event PositionClosed(address indexed user, uint256 size);
    event FundingRateUpdated(uint256 rate);
    event ShortPositionSet(address indexed short);
    event FundingSourceSet(address indexed source);
    event FundingAccrued(uint256 amount);

    constructor(address _underlying, address initialOwner, address _short, address _oracle)
        BaseStrategy(_underlying, initialOwner, "DeltaNeutral")
    {
        require(_short != address(0), "DeltaNeutral: zero short");
        require(_oracle != address(0), "DeltaNeutral: zero oracle");
        shortPosition = _short;
        oracle = _oracle;
        lastAccrual = block.timestamp;
    }

    /// @notice Accept native funding settlements from the venue (or forced sends).
    receive() external payable {}

    function name() external view override returns (string memory) {
        return "DeltaNeutral";
    }

    function setShortPosition(address short_) external onlyOwner nonReentrant {
        require(short_ != address(0), "DeltaNeutral: zero short");
        shortPosition = short_;
        emit ShortPositionSet(short_);
    }

    function setOracle(address oracle_) external onlyOwner nonReentrant {
        require(oracle_ != address(0), "DeltaNeutral: zero oracle");
        oracle = oracle_;
    }

    function setFundingSource(address source_) external onlyOwner nonReentrant {
        // slither-disable-next-line missing-zero-check
        fundingSource = source_; // address(0) intentionally disables accrual
        emit FundingSourceSet(source_);
    }

    function openPosition(uint256 size) external onlyOwner nonReentrant {
        require(size > 0, "DeltaNeutral: zero size");
        _settleAccrued(); // accrue at the old position size first
        positions[msg.sender] += size;
        delta += size;
        totalPrincipal += size;
        emit PositionOpened(msg.sender, size);
    }

    function closePosition() external onlyOwner nonReentrant {
        uint256 size = positions[msg.sender];
        require(size > 0, "DeltaNeutral: no position");
        _settleAccrued(); // accrue before shrinking
        require(delta >= size, "DeltaNeutral: underflow");
        delta -= size;
        positions[msg.sender] = 0;
        if (totalPrincipal >= size) totalPrincipal -= size;
        emit PositionClosed(msg.sender, size);
    }

    /// @notice Max annualized funding rate the strategy will ever accrue from.
    /// A broken/hostile oracle returning garbage cannot fabricate runaway
    /// yield or overflow `delta * rate * elapsed`.
    uint256 public constant MAX_RATE_BPS = 10_000; // 100% annualized

    /// @notice Fetch the live annualized funding rate from the oracle (clamped).
    function updateFunding() external onlyOwner nonReentrant {
        fundingRate = _fetchFundingRate();
        lastUpdate = block.timestamp;
        emit FundingRateUpdated(fundingRate);
    }

    function _fetchFundingRate() internal view returns (uint256) {
        if (oracle == address(0)) return 0;
        uint256 raw = IFundingOracle(oracle).getFundingRate();
        return raw > MAX_RATE_BPS ? MAX_RATE_BPS : raw; // clamp, don't revert — keeper liveness
    }

    /// @notice Accrue funding on `delta` since lastAccrual. Pays REAL USDC
    /// from the funding source into this strategy. Silent no-op while
    /// prerequisites are unset (testnet bootstrap) — never fabricates yield.
    /// slither-disable-next-line timestamp (elapsed-time accounting requires block.timestamp)
    function _settleAccrued() internal {
        uint256 elapsed = block.timestamp - lastAccrual; // compute BEFORE touching lastAccrual
        lastAccrual = block.timestamp;
        if (delta == 0 || fundingSource == address(0) || oracle == address(0)) return;
        // slither-disable-next-line incorrect-equality (zero = guard, not equality bug)
        if (fundingRate == 0 || elapsed == 0) return;
        // accrued = notional × annualRateBps × elapsed / (secondsPerYear × 10000)
        uint256 amount = (delta * fundingRate * elapsed) / (SECONDS_PER_YEAR * BPS_DENOM);
        if (amount == 0) return;
        // venue pays the accrued funding — real token movement
        // slither-disable-next-line low-level-calls (source set by owner; testnet mock in prod path)
        (bool ok, ) = fundingSource.call(
            abi.encodeWithSignature("payFunding(address,uint256)", address(this), amount)
        );
        require(ok, "DeltaNeutral: funding source failed");
        accruedFunding += amount; // effects after interaction — safe: source is trusted venue (owner-set)
        emit FundingAccrued(amount);
    }

    /// @notice Settle funding, refresh the rate, forward native ETH settlements
    /// to the short leg. When the VAULT harvests, accrued funding sweeps to it
    /// as real profit (USDC); keeper/owner harvests only settle (vault sweeps later).
    function _doHarvest() internal override returns (uint256 profit) {
        require(isActive, "DeltaNeutral: inactive");
        require(msg.sender == owner() || msg.sender == keeper || msg.sender == vault,
            "DeltaNeutral: not authorized");

        fundingRate = _fetchFundingRate();
        lastUpdate = block.timestamp;
        _settleAccrued();

        profit = 0;
        if (msg.sender == vault && accruedFunding > 0) {
            uint256 swept = accruedFunding;
            uint256 bal = underlying.balanceOf(address(this));
            if (swept > bal) swept = bal;
            if (swept > 0) {
                accruedFunding -= swept;
                underlying.safeTransfer(vault, swept);
                profit = swept; // BaseStrategy.harvest accounts it via totalDebt
            }
        }

        if (shortPosition != address(0) && isActive) {
            uint256 ethBal = address(this).balance;
            if (ethBal > 0) {
                // slither-disable-next-line arbitrary-send-eth (short set by owner)
                (bool success, ) = payable(shortPosition).call{value: ethBal}("");
                require(success, "DeltaNeutral: transfer failed");
            }
        }
    }
}
