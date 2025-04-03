// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface IFluxManager {
    function getRate(uint256 exchangeRate, bool quoteIn0Or1) external view returns (uint256);
    function getRateSafe(uint256 exchangeRate, bool quoteIn0Or1) external view returns (uint256);
}