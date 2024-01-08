## Borrow Lending Contract

**This contract will allow users to deposit allowed tokens or native chain asset (Mainnet ETH) backed by [API3](https://market.api3.org/dapis) oracles.**

Primary Functions:

-   **setTokensAvailable**: Add Token addresses and Price feeds of toksns your contract supports.
-   **setNativeTokenProxyAddress**: Manually set PriceFeed of Native Chain Assest (does not contain a token address).
-   **depositToken**: Use allowed tokens for collateral.
-   **depositNative**: Deposit chain native asset without having to wrap it.
-   **borrow**: Borrow up to 70% of deposited value (based on oracle value).
-   **repay**: Payback your debt.
-   **withdraw**: Take back deposits based on deposit and borrow balances.
-   **liquidate**: Pay back the debt of another user with a reward of deposited `Tokens` if health factor goes below 1.
-   **liquidateForNative**: Pay back the debt of another user with a reward of deposited `Native Asset` if health factor goes below 1.


## Usage

### Build

```shell
$ forge build
```

In the testing portion, 3 different oracles on Mocked each with their own contract.  On the local deployment one is set to a stable coin such as USDC, another is a Native Asset (ETH), and the other is the Wrapped Version of the Asset (WETH).

### Test
Test scenarios for deposit, borrow, repay, withdraw and liquidate

```shell
$ forge test -vv
```


### Deploy
Based on the .env.example file, use this script to deploy
- on mac source .env

```shell
forge script script/Borrow.s.sol:BorrowScript --rpc-url $PROVIDER_URL --verify --etherscan-api-key $ETHERSCAN_API_KEY --legacy --broadcast
```
