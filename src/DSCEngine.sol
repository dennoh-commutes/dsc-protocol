// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./Libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author TrustAuto
 * The system design is minimalistic as possible  and have the tokens maintain the 1 token = $1 peg.
 * The token has the properties:
 *     - Exogenous Collateral
 *     - Algorithmic Supply Control
 *     - Pegged to USD
 *     - Crypto Collateral Backing
 * Our DS system should always be overcollateralized to ensure the stability of the coin.
 * At no point should the value of all the collateral be less than the value of all the DSC tokens.
 *
 * It's similar to DAI if DAI had no governance, no fees and was only backed by wETH and wBTC.
 * @notice This contract is the core of the DSC system.
 * It handles all the logic for minting and redeeming DSC, as well as depositing and
 * withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI Stablecoin System).
 */

contract DSCEngine is ReentrancyGuard {
    //////////////////
    ////ERRORS///////
    //////////////////

    error DSCEngine__AmountMustBeAboveZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 HealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    DecentralizedStableCoin private immutable i_dsc;

    /////////////////
    //// Type ////
    ///////////////

    using OracleLib for AggregatorV3Interface;

    /////////////////
    //// EVENTS ////
    ///////////////

    event CollateralDeposited(
        address indexed user,
        address indexed tokenCollateralAddress,
        uint256 indexed collateralAmount
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        uint256 amountCollateral,
        address indexed tokenCollateralAddress
    );

    //////////////////////
    //// STATE VARS /////
    ////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200%
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address tokenAllowed => address priceFed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    modifier isAllowedToken(address token) {
        __isAllowedToken(token);
        _;
    }
    modifier moreThanZero(uint256 amount) {
        __moreThanZero(amount);
        _;
    }

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscEngine
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscEngine);
    }

    //////////////////////////////
    //// EXTERNAL FUNCTIONS /////
    ////////////////////////////

    /**
     * follows CEI
     * tokenCollateralAddress - the address of the token to Deposit as collateral
     * collateralAmount - the amount of collateral to deposit
     */

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 collateralAmount
    )
        public
        nonReentrant
        moreThanZero(collateralAmount)
        isAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += collateralAmount;

        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            collateralAmount
        );

        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice follows the  CEI patern
     * @param amountDSCToMint - the amount of decentralized stable coin to mint
     * @notice they must have more collateral value than the minimum threshhold
     */
    function mintDSC(
        uint256 amountDSCToMint
    ) public nonReentrant moreThanZero(amountDSCToMint) {
        s_DSCMinted[msg.sender] += amountDSCToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 collateralAmount,
        uint256 amountDSCToMint
    ) external moreThanZero(collateralAmount) {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintDSC(amountDSCToMint);
    }

    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public nonReentrant moreThanZero(amountCollateral) {
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * This function burns and redeem the underying collateral in one tx.
     * @param tokenCollateralAddress The collateralAddress to redeem.
     * @param amountCollateral The amountOfCollateral to redeem.
     * @param amountDSCToBurn The amount of DSC to burn.
     */
    function redeemCollateralForDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDSCToBurn
    ) external {
        burnDSC(amountDSCToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //Health factor checked in the redeemCollateral func
    }

    /**
     * Follows CEI
     * @param collateral The ERC20 collateral address to liquidate.
     * @param user The user who has brocken their health Factor.
     * Their healthFactor should be below MIN_HELATH_FACTOR
     * @param debtToCover The amount of DCS you want to burn to improve the user's
     * Health Factor.
     * @notice You can partially liquidate a user.
     * @notice You will get a bonus for taking the users funds.
     * @notice This function working assumes that the protocal will be roughly
     * 200% overcollateralized for  this to work.
     * @notice A known bug would be if the collateral were 100% or less collateralized
     * then we wouldn't be able to incentivise liquidators
     * @notice For example if the price of the collateral plummeted before anyone
     * could be liquidated
     */
    function liquidate(
        address user,
        address collateral,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;

        _redeemCollateral(
            collateral,
            totalCollateralToRedeem,
            user,
            msg.sender
        );
        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ////////////////////////////////////////
    //// PRIVATE AND INTERNAL FUNCTIONS ////
    ////////////////////////////////////////

    /**
     * @dev Low level Internal function! Do not call it unless the functions calling it
     * is checking for health factor being brocken
     */
    function _burnDSC(
        uint256 amountToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountToBurn);
    }

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        emit CollateralRedeemed(
            from,
            to,
            amountCollateral,
            tokenCollateralAddress
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close the user is to liquidation
     * @dev if the health factor drops below 1, the user is liquidatable
     * @param user - the user to calculate the health factor for
     * @return the health factor of the user
     */
    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDSCMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);

        if (totalDSCMinted == 0) {
            return type(uint256).max;
        }

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return ((collateralAdjustedForThreshold * PRECISION) / totalDSCMinted);
    }
    function _calculateHealthFactor(
        uint256 totalDSCMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDSCMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * 1e18) / totalDSCMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function __isAllowedToken(address token) internal view {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
    }

    function __moreThanZero(uint256 amount) internal pure {
        if (amount == 0) {
            revert DSCEngine__AmountMustBeAboveZero();
        }
    }

    ///////////////////////////////////////////
    //// PUBLIC EXTERNAL VIEW FUNCTIONS //////
    /////////////////////////////////////////

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.StaleCheckLatestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalValueInUsd += getUsdValue(token, amount);
        }
        return totalValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.StaleCheckLatestRoundData();
        uint256 adjustedPrice = (uint256(price) * ADDITIONAL_FEED_PRECISION) /
            PRECISION;
        return adjustedPrice * amount;
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        (totalDSCMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralDeposited(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function calculateHealthFactor(
        uint256 totalDSCMinted,
        uint256 collateralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUsd);
    }
    function getHealthFactor(address user) external view returns (uint256) {
        require(user != address(0), "Invalid user address");
        return _healthFactor(user);
    }
    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }
    function getCollateralBalanceOfUser(
        address user,
        address token
    ) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeeds[token];
    }
}
