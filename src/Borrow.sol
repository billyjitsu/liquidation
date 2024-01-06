// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/*
 Fun little borrow lend by @billyjitsu

 health factor = (total deposits - total borrows) / total deposits
    health factor = 1e8 = 100% = 1

 health factor = (collateral value * liquidation Threshold%) / borrows
*/
// import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@api3/contracts/v0.8/interfaces/IProxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error InsufficientBalance(uint256 available, uint256 required);
error ExceedsMaximumBorrowLimit(uint256 maxAllowed, uint256 requested);
error Overpayment(uint256 available, uint256 requested);
error ContractUnderFunded(uint256 available, uint256 required);
error OverLeveraged(uint256 maxAllowed, uint256 requested);
error TokenNotAllowed(address token);
error TransferFailed();
error zeroAmount();

contract BorrowLend is Ownable {
    address[] public allowedTokens;
    mapping(address => address) public priceFeedOfToken;
    mapping(address => uint256) public nativeDeposits;
    mapping(address => mapping(address => uint256)) public deposits;
    mapping(address => mapping(address => uint256)) public borrows;
    // mapping(address => address) public tokenToPriceFeed;

    address public nativeTokenProxyAddress;

    // 5% Liquidation Reward
    uint256 public constant LIQUIDATION_REWARD = 5;
    uint256 public constant LIQUIDATION_THRESHOLD = 70;
    uint256 public constant MIN_HEALH_FACTOR = 1e8;

    event DepositedNativeAsset(address indexed account, uint256 indexed amount);
    event DepositedToken(address indexed account, address indexed token, uint256 indexed amount);
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

    // function borrow(uint256 _amount) external {
    //     // Calculate the maximum amount that can still be borrowed
    //     uint256 alreadyBorrowed = borrows[msg.sender];
    //     uint256 maxBorrowAmount = (deposits[msg.sender] * 70 / 100) - alreadyBorrowed;

    //     if (address(this).balance < _amount) {
    //         revert ContractUnderFunded({available: address(this).balance, required: _amount});
    //     }

    //     if (_amount > maxBorrowAmount) {
    //         revert ExceedsMaximumBorrowLimit({maxAllowed: maxBorrowAmount, requested: _amount});
    //     }
    //     //update balance before transfer
    //     borrows[msg.sender] += _amount;
    //     (bool success,) = msg.sender.call{value: _amount}("");
    //     require(success, "Transfer failed.");
    // }

    // function repay() external payable {
    //     // Don't allow overpayment
    //     if (msg.value > borrows[msg.sender]) {
    //         revert Overpayment({available: borrows[msg.sender], requested: msg.value});
    //     }
    //     borrows[msg.sender] -= msg.value;
    // }

    // function withdraw(uint256 withdrawAmount) public {
    //     // Calculate the maximum amount that can be withdrawn
    //     uint256 maxWithdrawalAmount = calculateMaxWithdrawalAmount(msg.sender);

    //     // Ensure the withdrawal amount does not exceed the maximum allowed
    //     if (withdrawAmount > maxWithdrawalAmount) {
    //         revert OverLeveraged({maxAllowed: maxWithdrawalAmount, requested: withdrawAmount});
    //     }

    //     if (withdrawAmount > address(this).balance) {
    //         revert InsufficientBalance({available: address(this).balance, required: withdrawAmount});
    //     }

    //     // Update the deposit record after withdrawal
    //     deposits[msg.sender] -= withdrawAmount;

    //     // Transfer the amount
    //     (bool success,) = msg.sender.call{value: withdrawAmount}("");
    //     require(success, "Transfer failed.");
    // }

    // function calculateMaxWithdrawalAmount(address _user) public view returns (uint256) {
    //     uint256 currentDeposit = deposits[_user];
    //     uint256 currentBorrow = borrows[_user];

    //     // Calculate the minimum deposit required to keep the borrow amount within 70% of the deposit
    //     uint256 requiredDepositAfterWithdraw = currentBorrow * 100 / 70;

    //     // Calculate the maximum amount that can be withdrawn
    //     uint256 maxWithdrawalAmount =
    //         currentDeposit > requiredDepositAfterWithdraw ? currentDeposit - requiredDepositAfterWithdraw : 0;

    //     return maxWithdrawalAmount;
    // }

    // function userDepositedValue(address _user) public view returns (uint256) {
    //     uint256 ethPrice;
    //     uint256 ethTimestamp;
    //     (ethPrice, ethTimestamp) = readDataFeed(ethProxyAddress);
    //     uint256 usdcPrice;
    //     uint256 usdcTimestamp;
    //     (usdcPrice, usdcTimestamp) = readDataFeed(usdcProxyAddress);
    //     uint256 ethValue = deposits[_user] * ethPrice;
    //     uint256 usdcValue = deposits[_user] * usdcPrice;
    //     return ethValue + usdcValue;
    // }

    function userCollateralValue(address _user) view public returns (uint256) {
        uint256 totalDepositValue = 0;
        if(nativeDeposits[_user] > 0) {
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
        (price, ) = readDataFeed(priceFeedOfToken[_token]);
        return (_amount * price) / 1e18;
    }

    function calculateNativeAssetUSDValue(uint256 _amount) public view returns (uint256) {
        uint256 price;
        // uint256 ethTimestamp;
        (price, ) = readDataFeed(nativeTokenProxyAddress);
        return (_amount * price) / 1e18;
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