// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IDatum} from "src/interfaces/IDatum.sol";
import {IChainlinkOracle} from "src/interfaces/IChainlinkOracle.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

contract MockDatum is IDatum {
    using FixedPointMathLib for uint256;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTANTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint16 internal constant BPS_SCALE = 10_000;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ERRORS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error ChainlinkDatum__NegativeAnswer();
    error ChainlinkDatum__StaleAnswer();
    error ChainlinkDatum__InvalidExchangeRate(uint256 provided, uint256 lower, uint256 upper);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       IMMUTABLES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint8 public immutable decimals;
    uint256 public immutable answer;
    bool public immutable inverse;

    constructor(uint256 _answer, uint8 _decimals, bool _inverse) {
        answer = _answer;
        decimals = _decimals;
        inverse = _inverse;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    DATUM FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getDatum() public view returns (uint256) {
        if (inverse) {
            return uint256(10 ** decimals).mulDivDown(10 ** decimals, uint256(answer));
        } else {
            return uint256(answer);
        }
    }

    function getDatumInDecimals(uint8 requestedDecimals) external view returns (uint256) {
        uint256 datum = getDatum();

        if (decimals != requestedDecimals) {
            return datum.mulDivDown(10 ** requestedDecimals, 10 ** decimals);
        } else {
            return datum;
        }
    }

    function validateExchangeRateWithDatum(
        uint256 exchangeRate,
        uint8 exchangeRateDecimals,
        uint16 lowerBound,
        uint16 upperBound
    ) external view {
        uint256 datum = getDatum();
        uint256 lower = datum.mulDivDown(lowerBound, BPS_SCALE);
        uint256 upper = datum.mulDivDown(upperBound, BPS_SCALE);

        // Convert exchangeRate to be in terms of datum decimals.
        if (exchangeRateDecimals != decimals) {
            exchangeRate = exchangeRate.mulDivDown(10 ** decimals, 10 ** exchangeRateDecimals);
        }

        if (exchangeRate < lower || exchangeRate > upper) {
            revert ChainlinkDatum__InvalidExchangeRate(exchangeRate, lower, upper);
        }
    }
}
