// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface IDeployer {

    /**
     * @notice Contains data needed to send a transaction.
     */
    struct Tx {
        address target;
        bytes data;
        uint256 value;
    }

    /**
     * @notice Deploy some contract to a deterministic address.
     * @param name string used to derive salt for deployment
     * @dev Should be of form:
     *      "ContractName Version 0.0"
     *      Where the numbers after version are VERSION . SUBVERSION
     * @param creationCode the contract creation code to deploy
     *        - can be obtained by calling type(contractName).creationCode
     * @param constructorArgs the contract constructor arguments if any
     *        - must be of form abi.encode(arg1, arg2, ...)
     * @param value non zero if constructor needs to be payable
     */
    function deployContract(
        string calldata name,
        bytes memory creationCode,
        bytes calldata constructorArgs,
        uint256 value
    ) external returns (address);

    function bundleTxs(Tx[] calldata txs) external;

    function getAddress(string calldata name) external view returns (address);

    function convertNameToBytes32(string calldata name) external pure returns (bytes32);
}