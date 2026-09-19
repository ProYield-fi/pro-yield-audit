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

    function setShortPosition(address _short) external onlyOwner nonReentrant {
        shortPosition = _short;
    }

    function openPosition(uint256 size) external onlyOwner nonReentrant {
        positions[msg.sender] = size;
        delta += size;
    }

    function closePosition() external onlyOwner nonReentrant {
        uint256 size = positions[msg.sender];
        delta -= size;
        positions[msg.sender] = 0;
    }

    function updateFunding() external onlyOwner nonReentrant {
        fundingRate = _fetchFundingRate();
        lastUpdate = block.timestamp;
    }

    function _fetchFundingRate() internal pure returns (uint256) {
        return 0;
    }

    function harvest() external override nonReentrant {
        uint256 balance = address(this).balance;
        totalDebt += balance;
        (bool success, ) = shortPosition.call{value: balance}("");
        require(success, "DeltaNeutral: transfer failed");
    }
}
