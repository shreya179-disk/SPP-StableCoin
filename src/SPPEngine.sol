// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { defi_StableCoin } from "./defi_StableCoin.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// The system is designed to be as minimal as possible and have the tokens maintain a 1 token == $1 peg at all times.
// This is a stablecoin with the properties:
// - Exogenously Collateralized
// - Dollar Pegged
// - Algorithmically Stable
// It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.

contract SPPEngine is ReentrancyGuard {
    
    error SPPEngine_NeedsmorethanZero();
    error SPPEngine_TokenAddressAndPriceFeedAddressMustBeOfSameLength();
    error SPPEngine_NotAllowedToken();
    error SPPEngine_TransferFailed();
    error SPPEngine_MintFailed();
    error SPPEngine__BreaksHealthFactor( uint256 healthFactorValue);
    error SPPEngine_HealthfactorNotImproved();
    error SPPEngine__HealthFactorOk();
    

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address => address) private s_priceFeeds; // token to price feeds.
    mapping(address => mapping(address => uint256)) private s_collateralDeposited; // tokens deposited by the user
    mapping(address => uint256) private s_SPPMinted;
    address[] private s_collateralTokens;

    defi_StableCoin private immutable i_spp;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert SPPEngine_NeedsmorethanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert SPPEngine_NotAllowedToken();
        }
        _;
    }
    
    constructor(
        address[] memory tokenAddresses,
        address[] memory pricefeedAddresses,
        address sppaddress
    ) {
        if (tokenAddresses.length != pricefeedAddresses.length) { // Tokens allowed in our system. If they have price feeds, they are allowed.
            revert SPPEngine_TokenAddressAndPriceFeedAddressMustBeOfSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = pricefeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);

        }   
        i_spp = defi_StableCoin(sppaddress);
    }

    function depositCollateralAndMintSPP(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountSpptoMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintSPP(amountSpptoMint);
    }

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 tokenAmountCollateral
    ) public
        moreThanZero(tokenAmountCollateral)
        isAllowedToken(tokenCollateralAddress) 
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += tokenAmountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, tokenAmountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), tokenAmountCollateral);
        if (!success)
            revert SPPEngine_TransferFailed();
    }

    function redeemCollateralForSPP(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountSppToBurn) 
        external 
        moreThanZero(amountCollateral){
        _burnSPP(amountSppToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender,tokenCollateralAddress, amountCollateral);
        revertIfHealthFactorIsBroken(msg.sender);

    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) 
        external
        moreThanZero(amountCollateral) {
        _redeemCollateral(msg.sender, msg.sender,tokenCollateralAddress, amountCollateral);
        revertIfHealthFactorIsBroken(msg.sender);
    }
    
    // Collateral value > SPP amount
    function mintSPP(uint256 amountSPPtoMint) public moreThanZero(amountSPPtoMint) {
        s_SPPMinted[msg.sender] += amountSPPtoMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_spp.mint(msg.sender, amountSPPtoMint);

        if (minted != true) {
            revert SPPEngine_MintFailed();
        }
    }  

    function burnSPP(uint256 amount) external moreThanZero(amount) {
       _burnSPP(amount, msg.sender, msg.sender);
       revertIfHealthFactorIsBroken(msg.sender);

    }

    function getAccountInformation(address user) external view returns(uint256 totalSppMinted, uint256 collateralValueInUsd){
        return _getAccountInformation(user);
    }
    
    
    function _burnSPP(uint256 amountSspToBurn, address onBehalfOf, address sppFrom)private{
         s_SPPMinted [onBehalfOf] -= amountSspToBurn;
        bool success = i_spp. transferFrom(sppFrom, address (this), amountSspToBurn);
        if(!success){
            revert SPPEngine_TransferFailed();
        }
        i_spp.burn(amountSspToBurn);
    }


    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral
    ) private {
         s_collateralDeposited[from] [tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20 (tokenCollateralAddress).transfer (to, amountCollateral);
        if(!success){
            revert SPPEngine_TransferFailed();
        }

    }


    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalSppMinted, uint256 collateralValueInUsd)
    {
        totalSppMinted = s_SPPMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    // To remove a person's position to save the protocol.If someone is almost undercollateralized, we will pay you to liquidate them!
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover){
        uint256 startingUserHealthFactor = _healthFactor (user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert SPPEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // give them 10% bonus 
        //incentivize and implement a feature to liquidate in the event the protocol is insolvent
        uint256 bonusCollateral = tokenAmountFromDebtCovered * 10;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnSPP(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user) ;
        if (endingUserHealthFactor < startingUserHealthFactor){
            revert SPPEngine_HealthfactorNotImproved();
    }   
        revertIfHealthFactorIsBroken(msg.sender);  

    }


    // returns how close to liquidation a user is
     function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }
    // check if they have enough collateral revert if they dont 
    function revertIfHealthFactorIsBroken(address user) internal view {
    uint256 userHealthFactor = _healthFactor(user);
    if (userHealthFactor < MIN_HEALTH_FACTOR) {
        revert SPPEngine__BreaksHealthFactor(userHealthFactor);
      }
    
    }
    

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds [token] );
        (,int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * 1e18) / (uint256 (price) * ADDITIONAL_FEED_PRECISION);
    }

    // loop through each colleral token, get the amount they have deposited, and map it to the price, to get the USD value
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i<s_collateralTokens. length; i++){
        address token = s_collateralTokens[i];
        uint256 amount = s_collateralDeposited[user][token];
        totalCollateralValueInUsd +=_getUsdValue(token, amount);
        
        }
    }
    
    function _calculateHealthFactor(uint256 totalSppMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalSppMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * 1e18) / totalSppMinted;
    }

    function _getUsdValue(address token, uint256 amount) private view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed. latestRoundData();
        //1 ETH = $1000
        // the returned value will be 1000 * 1e8
        return ((uint256(price)*ADDITIONAL_FEED_PRECISION) * amount)/1e18;
    }
      function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }


}