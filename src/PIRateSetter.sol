// Copyright (C) 2020 Maker Ecosystem Growth Holdings, INC, Reflexer Labs, INC.

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity 0.6.7;

import "geb-treasury-reimbursement/math/GebMath.sol";

abstract contract OracleLike {
    function getResultWithValidity() virtual external view returns (uint256, bool);
}
abstract contract OracleRelayerLike {
    function redemptionPrice() virtual external returns (uint256);
}
abstract contract SetterRelayer {
    function relayRate(uint256, address) virtual external;
}
abstract contract PIDCalculator {
    function computeRate(uint256, uint256, uint256) virtual external returns (uint256);
    function rt(uint256, uint256, uint256) virtual external view returns (uint256);
    function pscl() virtual external view returns (uint256);
    function tlv() virtual external view returns (uint256);
}

contract PIRateSetter is GebMath {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "PIRateSetter/account-not-authorized");
        _;
    }

    // --- Variables ---
    // Last recorded system coin market price
    uint256 public latestMarketPrice;               // [ray]
    // When the price feed was last updated
    uint256 public lastUpdateTime;                  // [timestamp]
    // Enforced gap between calls
    uint256 public updateRateDelay;                 // [seconds]

    // --- System Dependencies ---
    // OSM or medianizer for the system coin
    OracleLike                public orcl;
    // OracleRelayer where the redemption price is stored
    OracleRelayerLike         public oracleRelayer;
    // The contract that will pass the new redemption rate to the oracle relayer
    SetterRelayer             public setterRelayer;
    // Calculator for the redemption rate
    PIDCalculator             public pidCalculator;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ModifyParameters(
      bytes32 parameter,
      address addr
    );
    event ModifyParameters(
      bytes32 parameter,
      uint256 val
    );
    event UpdateRedemptionRate(
        uint marketPrice,
        uint redemptionPrice,
        uint redemptionRate
    );
    event FailUpdateRedemptionRate(
        bytes reason
    );

    constructor(
      address oracleRelayer_,
      address setterRelayer_,
      address orcl_,
      address pidCalculator_,
      uint256 updateRateDelay_
    ) public {
        require(oracleRelayer_ != address(0), "PIRateSetter/null-oracle-relayer");
        require(setterRelayer_ != address(0), "PIRateSetter/null-setter-relayer");
        require(orcl_ != address(0), "PIRateSetter/null-orcl");
        require(pidCalculator_ != address(0), "PIRateSetter/null-calculator");

        authorizedAccounts[msg.sender] = 1;

        oracleRelayer    = OracleRelayerLike(oracleRelayer_);
        setterRelayer    = SetterRelayer(setterRelayer_);
        orcl             = OracleLike(orcl_);
        pidCalculator    = PIDCalculator(pidCalculator_);

        updateRateDelay  = updateRateDelay_;

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("orcl", orcl_);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
        emit ModifyParameters("setterRelayer", setterRelayer_);
        emit ModifyParameters("pidCalculator", pidCalculator_);
        emit ModifyParameters("updateRateDelay", updateRateDelay_);
    }

    // --- Boolean Logic ---
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }

    // --- Management ---
    /*
    * @notify Modify the address of a contract that the setter is connected to
    * @param parameter Contract name
    * @param addr The new contract address
    */
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        require(addr != address(0), "PIRateSetter/null-addr");
        if (parameter == "orcl") orcl = OracleLike(addr);
        else if (parameter == "oracleRelayer") oracleRelayer = OracleRelayerLike(addr);
        else if (parameter == "setterRelayer") setterRelayer = SetterRelayer(addr);
        else if (parameter == "pidCalculator") {
          pidCalculator = PIDCalculator(addr);
        }
        else revert("PIRateSetter/modify-unrecognized-param");
        emit ModifyParameters(
          parameter,
          addr
        );
    }
    /*
    * @notify Modify a uint256 parameter
    * @param parameter The parameter name
    * @param val The new parameter value
    */
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        require(val > 0, "PIRateSetter/null-val");
        if (parameter == "updateRateDelay") {
          updateRateDelay = val;
        }
        else revert("PIRateSetter/modify-unrecognized-param");
        emit ModifyParameters(
          parameter,
          val
        );
    }

    // --- Feedback Mechanism ---
    /**
    * @notice Compute and set a new redemption rate
    * @param feeReceiver The proposed address that should receive the reward for calling this function
    *        (unless it's address(0) in which case msg.sender will get it)
    **/
    function updateRate(address feeReceiver) external {
        // The fee receiver must not be null
        require(feeReceiver != address(0), "PIRateSetter/null-fee-receiver");
        // Check delay between calls
        require(either(subtract(now, lastUpdateTime) >= updateRateDelay, lastUpdateTime == 0), "PIRateSetter/wait-more");
        // Get price feed updates
        (uint256 marketPrice, bool hasValidValue) = orcl.getResultWithValidity();
        // If the oracle has a value
        require(hasValidValue, "PIRateSetter/invalid-oracle-value");
        // If the price is non-zero
        require(marketPrice > 0, "PIRateSetter/null-price");
        // Get the latest redemption price
        uint redemptionPrice = oracleRelayer.redemptionPrice();
        // Store the latest market price
        latestMarketPrice = ray(marketPrice);
        // Calculate the rate
        uint256 tlv        = pidCalculator.tlv();
        uint256 iapcr      = rpower(pidCalculator.pscl(), tlv, RAY);
        uint256 calculated = pidCalculator.computeRate(
            marketPrice,
            redemptionPrice,
            iapcr
        );
        // Store the timestamp of the update
        lastUpdateTime = now;
        // Update the rate using the setter relayer
        try setterRelayer.relayRate(calculated, feeReceiver) {
          // Emit success event
          emit UpdateRedemptionRate(
            ray(marketPrice),
            redemptionPrice,
            calculated
          );
        }
        catch(bytes memory revertReason) {
          emit FailUpdateRedemptionRate(
            revertReason
          );
        }
    }

    // --- Getters ---
    /**
    * @notice Get the market price from the system coin oracle
    **/
    function getMarketPrice() external view returns (uint256) {
        (uint256 marketPrice, ) = orcl.getResultWithValidity();
        return marketPrice;
    }
    /**
    * @notice Get the redemption and the market prices for the system coin
    **/
    function getRedemptionAndMarketPrices() external returns (uint256 marketPrice, uint256 redemptionPrice) {
        (marketPrice, ) = orcl.getResultWithValidity();
        redemptionPrice = oracleRelayer.redemptionPrice();
    }
}
