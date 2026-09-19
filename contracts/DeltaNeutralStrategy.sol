// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";

contract DeltaNeutralStrategy is BaseStrategy {
    address public shortPosition;
    uint256 public delta;
    uint256 public fundingRate;
    uint256 public lastUpdate;
    mapping(address => uint256) public positions;
    
    constructor(address _underlying, address _owner, address _short) 
        BaseStrategy(_underlying, _owner) 
    {
        shortPosition = _short;
    }

    function setShortPosition(address _short) external onlyOwner {
        shortPosition = _short;
    }

    function openPosition(uint256 size) external {
        positions[msg.sender] = size;
        delta += size;
    }

    function closePosition() external {
        uint256 size = positions[msg.sender];
        delta -= size;
        positions[msg.sender] = 0;
    }

    function updateFunding() external {
        fundingRate = _fetchFundingRate();
        lastUpdate = block.timestamp;
    }

    function _fetchFundingRate() internal pure returns (uint256) {
        return 0;
    }

    function harvest() external override {
        (bool success, ) = shortPosition.call{value: address(this).balance}("");
        totalDebt += address(this).balance;
    }
}
