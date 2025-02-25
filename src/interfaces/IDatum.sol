// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface IDatum {
    function getDatum() external view returns (uint256);
    function validateExchangeRateWithDatum(
        uint256 exchangeRate,
        uint8 exchangeRateDecimals,
        uint16 lowerBound,
        uint16 upperBound
    ) external view returns (bool);
}
