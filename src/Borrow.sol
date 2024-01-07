// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/*
 Fun little borrow lend by @billyjitsu


    health factor = 1e8 = 100% = 1

 health factor = (collateral value * liquidation Threshold%) / borrows
*/
// import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@api3/contracts/v0.8/interfaces/IProxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/Test.sol";

error InsufficientBalance(uint256 available, uint256 required);
error ExceedsMaximumBorrowLimit(uint256 maxAllowed, uint256 requested);
error Overpayment(uint256 available, uint256 requested);
error ContractUnderFunded(uint256 available, uint256 required);
error OverLeveraged(uint256 maxAllowed, uint256 requested);
error TokenNotAllowed(address token);
error TransferFailed();
error zeroAmount();
error NotLiquidatable(uint256 healthFactor, uint256 minHealthFactor);
error IncorrectRepaymentToken(address token);
error NoRewardForLiquidation(uint256 rewardAmount, uint256 halfDebtInUSD);

contract BorrowLend is Ownable {
    address[] public allowedTokens;
    mapping(address => address) public priceFeedOfToken;
    mapping(address => uint256) public nativeDeposits;
    mapping(address => mapping(address => uint256)) public deposits;
    mapping(address => mapping(address => uint256)) public borrows;

    address public nativeTokenProxyAddress;

    uint256 public constant LIQUIDATION_REWARD = 5;
    uint256 public constant LIQUIDATION_THRESHOLD = 70;
    uint256 public constant MIN_HEALH_FACTOR = 1e8;

    event DepositedNativeAsset(address indexed account, uint256 indexed amount);
    event DepositedToken(address indexed account, address indexed token, uint256 indexed amount);
    event Borrow(address indexed account, address indexed token, uint256 indexed amount);
    event Repay(address indexed account, address indexed token, uint256 indexed amount);
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);
    event WithdrawNative(address indexed account, uint256 indexed amount);
    event Liquidate(address indexed account, address indexed repayToken, address indexed rewardToken, uint256 halfDebtInEth, address liquidator);
    event LiquidateForNative(address indexed account, address indexed repayToken, uint256 halfDebtInEth, address liquidator);
    event AllowedTokenSet(address indexed token, address indexed priceFeed);

    constructor() Ownable(msg.sender) {}

    modifier isAllowedToken(address _token) {
        if (priceFeedOfToken[_token] == address(0)) revert TokenNotAllowed(_token);
        _;
    }

    function setNativeTokenProxyAddress(address _nativeTokenProxyAddress) external onlyOwner {
        nativeTokenProxyAddress = _nativeTokenProxyAddress;
    }

    function readDataFeed(address _priceFeed) public view returns (uint256, uint256) {
        (int224 value, uint256 timestamp) = IProxy(_priceFeed).read();
        //convert price to UINT256
        uint256 price = uint224(value);
        return (price, timestamp);
    }

    // Chain native asset
    function depositNative() external payable {
        if (msg.value == 0) revert zeroAmount();
        nativeDeposits[msg.sender] += msg.value;
        emit DepositedNativeAsset(msg.sender, msg.value);
    }

    function depositToken(address _token, uint256 _amount) external isAllowedToken(_token) {
        if (_amount == 0) revert zeroAmount();
        bool success = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if (!success) revert TransferFailed();
        deposits[msg.sender][_token] += _amount;
        emit DepositedToken(msg.sender, _token, _amount);
    }

    function borrow(address _token, uint256 _amount) external {
        // Calculate the maximum amount that can still be borrowed
        if (_amount > IERC20(_token).balanceOf(address(this))) {
            revert ContractUnderFunded({available: address(this).balance, required: _amount});
        }
        //update balance before transfer
        borrows[msg.sender][_token] += _amount;
        bool success = IERC20(_token).transfer(msg.sender, _amount);
        if (!success) revert TransferFailed();
        emit Borrow(msg.sender, _token, _amount);
        // check the health factor after borrow
        if (healthFactor(msg.sender) < MIN_HEALH_FACTOR) {
            revert OverLeveraged({maxAllowed: MIN_HEALH_FACTOR, requested: healthFactor(msg.sender)});
        }
    }

    function repay(address _token, uint256 _amount) external payable {
        if (_amount == 0) revert zeroAmount();
        repayFunction(msg.sender, _token, _amount);
        emit Repay(msg.sender, _token, _amount);
    }

    // Internal function to repay if either original user repays or liquidator repays
    function repayFunction(address _account, address _token, uint256 _amount) internal {
        if (_amount > borrows[_account][_token]) {
            revert Overpayment({available: borrows[_account][_token], requested: _amount});
        }

        // bool success = IERC20(_token).transferFrom(_account, address(this), _amount);
        bool success = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if (!success) revert TransferFailed();
        //Update debt balance after transfer
        borrows[_account][_token] -= _amount;
    }

    function liquidate(address _account, address _tokenToRepay, address _rewardToken) external payable {
        if (healthFactor(_account) >= MIN_HEALH_FACTOR) {
            revert NotLiquidatable({healthFactor: healthFactor(_account), minHealthFactor: MIN_HEALH_FACTOR});
        }
        uint256 halfDebt = borrows[_account][_tokenToRepay] / 2;
        uint256 halfDebtInUSD = calculateUSDValue(_tokenToRepay, halfDebt);
        if (halfDebtInUSD == 0) revert IncorrectRepaymentToken(_tokenToRepay);
        uint256 rewardAmountInUSD = (halfDebtInUSD * LIQUIDATION_REWARD) / 100;
        uint256 totalRewardAmountInRewardToken = calculateUSDValue(_rewardToken, rewardAmountInUSD + halfDebtInUSD);
        if (totalRewardAmountInRewardToken == 0) revert NoRewardForLiquidation({rewardAmount: rewardAmountInUSD, halfDebtInUSD: halfDebtInUSD});
        // (uint256 halfDebt, uint256 halfDebtInUSD, uint256 totalRewardAmountInRewardToken) = liquidationCalculation(_account, _tokenToRepay, _rewardToken);
        repayFunction(_account, _tokenToRepay, halfDebt);
        bool success = IERC20(_rewardToken).transferFrom(msg.sender, _account, totalRewardAmountInRewardToken);
        if (!success) revert TransferFailed();
        emit Liquidate(_account, _tokenToRepay, _rewardToken, halfDebtInUSD, msg.sender);
    }

    function liquidateForNative(address _account, address _tokenToRepay) external {
        if (healthFactor(_account) >= MIN_HEALH_FACTOR) {
            revert NotLiquidatable({healthFactor: healthFactor(_account), minHealthFactor: MIN_HEALH_FACTOR});
        }
        uint256 halfDebt = borrows[_account][_tokenToRepay] / 2;
        console2.log("Half Debt: ", halfDebt);
        uint256 halfDebtInUSD = calculateUSDValue(_tokenToRepay, halfDebt);
        console2.log("Half Debt in USD: ", halfDebtInUSD);
        if (halfDebtInUSD == 0) revert IncorrectRepaymentToken(_tokenToRepay);
        uint256 rewardAmountInUSD = (halfDebtInUSD * LIQUIDATION_REWARD) / 100;
        console2.log("Reward Amount in USD: ", rewardAmountInUSD);
        uint256 totalRewardAmountInRewardToken = calculateNativeAssetValueFromUSD(rewardAmountInUSD + halfDebtInUSD);
        console2.log("Total Reward Amount in Reward Token: ", totalRewardAmountInRewardToken);
        if (totalRewardAmountInRewardToken == 0) revert NoRewardForLiquidation({rewardAmount: rewardAmountInUSD, halfDebtInUSD: halfDebtInUSD});
        console2.log("made it past liquidation calculation");
        repayFunction(_account, _tokenToRepay, halfDebt);
        bool success = payable(msg.sender).send(totalRewardAmountInRewardToken);
        if (!success) revert TransferFailed();
        emit LiquidateForNative(_account, _tokenToRepay, halfDebtInUSD, msg.sender);
    }

    // function liquidationCalculation(address _account, address _tokenToRepay, address _rewardToken) internal view returns (uint256, uint256, uint256) {
    //     uint256 halfDebt = borrows[_account][_tokenToRepay] / 2;
    //     uint256 halfDebtInUSD = calculateUSDValue(_tokenToRepay, halfDebt);
    //     if (halfDebtInUSD == 0) revert IncorrectRepaymentToken(_tokenToRepay);
    //     console2.log("made it past halfDebtInUSD");
    //     uint256 rewardAmountInUSD = (halfDebtInUSD * LIQUIDATION_REWARD) / 100;
    //     uint256 totalRewardAmountInRewardToken = calculateUSDValue(_rewardToken, rewardAmountInUSD + halfDebtInUSD);
    //     console2.log("made it past totalRewardAmountInRewardToken");
    //     if (totalRewardAmountInRewardToken == 0) revert NoRewardForLiquidation({rewardAmount: rewardAmountInUSD, halfDebtInUSD: halfDebtInUSD});
    //     return (halfDebt, halfDebtInUSD, totalRewardAmountInRewardToken);
    // }

    function withdraw(address _token, uint256 _amount) external {
        if (_amount == 0) revert zeroAmount();
        if (_amount > deposits[msg.sender][_token]) {
            revert InsufficientBalance({available: deposits[msg.sender][_token], required: _amount});
        }
        //update balance before transfer
        deposits[msg.sender][_token] -= _amount;
        bool success = IERC20(_token).transfer(msg.sender, _amount);
        if (!success) revert TransferFailed();
        if (healthFactor(msg.sender) < MIN_HEALH_FACTOR) {
            revert OverLeveraged({maxAllowed: MIN_HEALH_FACTOR, requested: healthFactor(msg.sender)});
        }
        emit Withdraw(msg.sender, _token, _amount);
    }

    function withdrawNative(uint256 _amount) external {
        if (_amount == 0) revert zeroAmount();
        if (_amount > nativeDeposits[msg.sender]) {
            revert InsufficientBalance({available: nativeDeposits[msg.sender], required: _amount});
        }
        //update balance before transfer
        nativeDeposits[msg.sender] -= _amount;
        bool success = payable(msg.sender).send(_amount);
        if (!success) revert TransferFailed();
        if (healthFactor(msg.sender) < MIN_HEALH_FACTOR) {
            revert OverLeveraged({maxAllowed: MIN_HEALH_FACTOR, requested: healthFactor(msg.sender)});
        }
        emit WithdrawNative(msg.sender, _amount);
    }

    function healthFactor(address _user) public view returns (uint256) {
        (uint256 totalBorrowValue, uint256 totalDepositValue) = userInformation(_user);
        uint256 userCollateral = (totalDepositValue * LIQUIDATION_THRESHOLD) / 100;
        if (totalBorrowValue == 0) return 100e8;
        return (userCollateral * 1e8) / totalBorrowValue;
    }

    function userInformation(address _user) public view returns (uint256, uint256) {
        uint256 totalDepositValue = calculateDepositValue(_user);
        uint256 totalBorrowValue = calculateBorrowValue(_user);
        return (totalBorrowValue, totalDepositValue);
    }

    function calculateDepositValue(address _user) public view returns (uint256) {
        uint256 totalDepositValue = 0;
        if (nativeDeposits[_user] > 0) {
            totalDepositValue += calculateNativeAssetUSDValue(nativeDeposits[_user]);
        }
        for (uint256 i = 0; i < allowedTokens.length; ++i) {
            address token = allowedTokens[i];
            uint256 depositedTokenAmount = deposits[_user][token];
            if (depositedTokenAmount > 0) {
                totalDepositValue += calculateUSDValue(token, depositedTokenAmount);
            }
        }
        return totalDepositValue;
    }

    function calculateBorrowValue(address _user) public view returns (uint256) {
        uint256 totalBorrowValue = 0;
        for (uint256 i = 0; i < allowedTokens.length; ++i) {
            address token = allowedTokens[i];
            uint256 borrowedTokenAmount = borrows[_user][token];
            if (borrowedTokenAmount > 0) {
                totalBorrowValue += calculateUSDValue(token, borrowedTokenAmount);
            }
        }
        return totalBorrowValue;
    }

    function userCollateralValue(address _user) public view returns (uint256) {
        uint256 totalDepositValue = 0;
        if (nativeDeposits[_user] > 0) {
            totalDepositValue += calculateNativeAssetUSDValue(nativeDeposits[_user]);
        }
        for (uint256 i = 0; i < allowedTokens.length; ++i) {
            address token = allowedTokens[i];
            uint256 depositedTokenAmount = deposits[_user][token];
            if (depositedTokenAmount > 0) {
                totalDepositValue += calculateUSDValue(token, depositedTokenAmount);
            }
        }
        return totalDepositValue;
    }

    function calculateUSDValue(address _token, uint256 _amount) public view returns (uint256) {
        uint256 price;
        //  uint256 timestamp;
        (price,) = readDataFeed(priceFeedOfToken[_token]);
        return (_amount * price) / 1e18;
    }

    function calculateNativeAssetUSDValue(uint256 _amount) public view returns (uint256) {
        uint256 price;
        // uint256 ethTimestamp;
        (price,) = readDataFeed(nativeTokenProxyAddress);
        return (_amount * price) / 1e18;
    }

    function calculateTokenValueFromUSD(address _token, uint256 _amount) public view returns (uint256) {
        uint256 price;
        // uint256 timestamp;
        (price,) = readDataFeed(priceFeedOfToken[_token]);
        return (_amount * 1e18) / price;
    }

    function calculateNativeAssetValueFromUSD(uint256 _amount) public view returns (uint256) {
        uint256 price;
        // uint256 timestamp;
        (price,) = readDataFeed(nativeTokenProxyAddress);
        return (_amount * 1e18) / price;
    }

    // view total amount of ETH in contract for testing
    function getTotalContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function setTokensAvailable(address _token, address _priceFeed) external onlyOwner {
        bool exists = false;
        uint256 allowedTokensLength = allowedTokens.length;
        for (uint256 i = 0; i < allowedTokensLength; ++i) {
            if (allowedTokens[i] == _token) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            allowedTokens.push(_token);
        }
        priceFeedOfToken[_token] = _priceFeed;
        emit AllowedTokenSet(_token, _priceFeed);
    }
}
