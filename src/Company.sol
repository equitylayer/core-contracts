// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./mixins/CompanyGovernance.sol";
import "./mixins/CompanyShareClasses.sol";
import "./mixins/CompanyDividends.sol";

/// @title Company
/// @notice Main company contract
/// @dev Mixins: Governance, ShareClasses, Dividends.
contract Company is Initializable, CompanyGovernance, CompanyShareClasses, CompanyDividends {
    string public constant VERSION = "0.9.0";

    struct InitParams {
        address board;
        IVault vault;
        ICompanyFactory factory;
        ShareholderRegistry shareholderRegistry;
        VestingSchedule vestingSchedule;
        OptionPool optionPool;
        ISAFE safe;
        IFundraise fundraise;
        IConvertibleNote convertibleNote;
        IEquityIssuance issuance;
        IDataRoom dataRoom;
        IERC20 paymentToken;
        string name;
        string ticker;
        string metadataUri;
        uint16 countryCode;
        uint8 entityType;
    }

    function initialize(InitParams calldata p) external initializer {
        if (p.board == address(0)) revert ZeroAddress();
        if (address(p.factory) == address(0)) revert ZeroAddress();
        if (address(p.shareholderRegistry) == address(0)) revert ZeroAddress();
        if (address(p.vestingSchedule) == address(0)) revert ZeroAddress();
        if (address(p.optionPool) == address(0)) revert ZeroAddress();
        if (address(p.safe) == address(0)) revert ZeroAddress();
        if (address(p.fundraise) == address(0)) revert ZeroAddress();
        if (address(p.convertibleNote) == address(0)) revert ZeroAddress();
        if (address(p.issuance) == address(0)) revert ZeroAddress();
        if (address(p.dataRoom) == address(0)) revert ZeroAddress();
        if (address(p.paymentToken) == address(0)) revert ZeroAddress();
        if (p.countryCode == 0) revert InvalidInput();

        board = p.board;
        vault = p.vault;
        factory = p.factory;
        shareholderRegistry = p.shareholderRegistry;
        vestingSchedule = p.vestingSchedule;
        optionPool = p.optionPool;
        safe = p.safe;
        fundraise = p.fundraise;
        convertibleNote = p.convertibleNote;
        issuance = p.issuance;
        dataRoom = p.dataRoom;
        paymentToken = p.paymentToken;
        name = p.name;
        ticker = p.ticker;
        metadataURI = p.metadataUri;
        countryCode = p.countryCode;
        entityType = p.entityType;
    }

    /// @inheritdoc ICompany
    function operator() external view returns (address) {
        return factory.operator();
    }
}
