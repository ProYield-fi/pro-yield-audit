// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DeltaNeutralStrategy is BaseStrategy {
    address public shortPosition;
    uint256 public delta;
    uint256 public fundingRate;
    uint256 public lastUpdate;
    mapping(address => uint256) public positions;
    address public oracle;

    event PositionOpened(address indexed user, uint256 size);
    event PositionClosed(address indexed user, uint256 size);
    event FundingRateUpdated(uint256 rate);
    event ShortPositionSet(address indexed short);

    constructor(address _underlying, address initialOwner, address _short, address _oracle)
        BaseStrategy(_underlying, initialOwner, "DeltaNeutral")
    {
        require(_short != address(0), "DeltaNeutral: zero short");
        require(_oracle != address(0), "DeltaNeutral: zero oracle");
        shortPosition = _short;
        oracle = _oracle;
    }

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

    function openPosition(uint256 size) external onlyOwner nonReentrant {
        require(size > 0, "DeltaNeutral: zero size");
        positions[msg.sender] += size;
        delta += size;
        emit PositionOpened(msg.sender, size);
    }

    function closePosition() external onlyOwner nonReentrant {
        uint256 size = positions[msg.sender];
        require(size > 0, "DeltaNeutral: no position");
        require(delta >= size, "DeltaNeutral: underflow");
        delta -= size;
        positions[msg.sender] = 0;
        emit PositionClosed(msg.sender, size);
    }

    function updateFunding() external onlyOwner nonReentrant {
        fundingRate = _fetchFundingRate();
        lastUpdate = block.timestamp;
        emit FundingRateUpdated(fundingRate);
    }

    function _fetchFundingRate() internal view returns (uint256) {
        if (oracle == address(0)) return 0;
        // In production: return IOracle(oracle).getFundingRate();
        return 0;
    }

    function _doHarvest() internal override returns (uint256) {
        uint256 profit = 0;
        if (shortPosition != address(0) && delta > 0 && isActive && msg.sender == owner()) {
            uint256 balance = address(this).balance;
            if (balance > 0) {
                uint256 _bal = balance;
                bool success = payable(shortPosition).send(balance);
                require(success, "DeltaNeutral: transfer failed");
                profit = balance;
            }
        }
        return profit;
    }

}
