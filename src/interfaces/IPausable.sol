// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface IPausable {
    function pause() external;
    function unpause() external;
}
