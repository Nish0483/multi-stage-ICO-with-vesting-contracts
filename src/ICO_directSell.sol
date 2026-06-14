// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
@dev ICO contract for direct token sale
**/
contract ICO_directSell is AccessControl {
    using SafeERC20 for IERC20;

    constructor(
        address _icoToken,
        uint pricePerToken, //eg 1e13 for 0.00001 usd
        PaymentTokenConfig[] memory _configs
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        icoStartTime = block.timestamp;
        icoEndTime = block.timestamp + 30 days;
        icoToken = IERC20(_icoToken);
        icoPrice = pricePerToken;
        for (uint256 i = 0; i < _configs.length; i++) {
            _setPaymentTokenPricefeed(_configs[i].token, _configs[i].priceFeed);
        }
    }

    struct PaymentTokenConfig {
        address token;
        address priceFeed;
    }

    event TokensPurchased(
        address indexed buyer,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 tokensReceived
    );
    event PaymentTokenSet(address indexed token, address indexed priceFeed);
    event WithdrawnETH(address indexed to, uint256 amount);
    event WithdrawnERC20(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    mapping(address => address) public tokenPriceFeeds;

    IERC20 public immutable icoToken;
    uint256 public immutable icoPrice;
    uint public icoStartTime;
    uint public icoEndTime;

    function buyTokenWithERC20(
        address _paymentToken,
        uint256 _paymentTokenAmount
    ) public {
        require(
            block.timestamp >= icoStartTime && block.timestamp <= icoEndTime,
            "ICO inactive"
        );
        require(_paymentTokenAmount > 0, "Amount zero");

        address feedAddress = tokenPriceFeeds[_paymentToken];
        require(feedAddress != address(0), "Token not supported");

        uint8 tokenDecimals = IERC20Metadata(_paymentToken).decimals();

        (uint price, uint oracleDecimals) = getTokenPrice(_paymentToken);

        uint256 usdValue = (_paymentTokenAmount * price * 1e18) /
            (10 ** tokenDecimals * 10 ** oracleDecimals);

        uint256 tokenToReceive = (usdValue * 1e18) / icoPrice;

        require(
            icoToken.balanceOf(address(this)) >= tokenToReceive,
            "Not enough ICO tokens"
        );

        IERC20(_paymentToken).safeTransferFrom(
            msg.sender,
            address(this),
            _paymentTokenAmount
        );
        icoToken.safeTransfer(msg.sender, tokenToReceive);

        emit TokensPurchased(
            msg.sender,
            _paymentToken,
            _paymentTokenAmount,
            tokenToReceive
        );
    }

    function buyTokenWithNative() external payable {
        require(
            block.timestamp >= icoStartTime && block.timestamp <= icoEndTime,
            "ICO inactive"
        );
        require(msg.value > 0, "Amount zero");

        (uint256 price, uint256 oracleDecimals) = getTokenPrice(address(0));

        uint256 usdValue = (msg.value * price) / (10 ** oracleDecimals);

        uint256 tokenToReceive = (usdValue * 1e18) / icoPrice;

        require(
            icoToken.balanceOf(address(this)) >= tokenToReceive,
            "Not enough ICO tokens"
        );

        icoToken.safeTransfer(msg.sender, tokenToReceive);
        emit TokensPurchased(msg.sender, address(0), msg.value, tokenToReceive);
    }

    function getTokenPrice(
        address _paymentToken
    ) public view returns (uint256, uint8) {
        address feedAddress = tokenPriceFeeds[_paymentToken];
        require(feedAddress != address(0), "Token not supported");
        // chainlink oracle to get tokens price
        AggregatorV3Interface feed = AggregatorV3Interface(feedAddress);
        (, int256 price, , , ) = feed.latestRoundData();
        uint256 tokenPrice = uint256(price);
        uint8 decimals = feed.decimals();
        return (tokenPrice, decimals);
    }

    function _setPaymentTokenPricefeed(
        address _token,
        address _priceFeed
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_priceFeed != address(0), "Invalid price feed");

        tokenPriceFeeds[_token] = _priceFeed;
        emit PaymentTokenSet(_token, _priceFeed);
    }

    // Function to withdraw ETH from the contract
    function withdrawETH(
        uint256 amount,
        address to
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(this).balance >= amount, "Insufficient ETH balance");
        payable(to).transfer(amount);
        emit WithdrawnETH(to, amount);
    }

    // Function to withdraw ERC20 tokens from the contract
    function withdrawERC20(
        address tokenAddress,
        uint256 amount,
        address to
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tokenAddress != address(0), "Invalid token address");
        IERC20 token = IERC20(tokenAddress);
        require(
            token.balanceOf(address(this)) >= amount,
            "Insufficient token balance"
        );
        token.safeTransfer(to, amount);
        emit WithdrawnERC20(tokenAddress, to, amount);
    }
}
