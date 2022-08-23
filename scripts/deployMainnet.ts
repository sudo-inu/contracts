import { ethers } from "hardhat";

import {
  DefaultController__factory,
  SudoController__factory,
  SudoInuLP__factory,
  SnackToken__factory,
  SnackShack__factory,
  WrappedXminu__factory,
  SqrtMath__factory,
} from "../typechain";

enum PoolType {
  TOKEN = 0,
  NFT = 1,
  TRADE = 2,
}

enum FarmType {
  STANDARD = 0,
  SCALED = 1,
}

const FACTORY = "0xb16c1342E617A5B6E4b631EB114483FDB289c0A4";
const LINEAR_CURVE = "0x5B6aC51d9B1CeDE0068a1B26533CAce807f883Ee";
const EXPONENTIAL_CURVE = "0x432f962D8209781da23fB37b6B59ee15dE7d9841";
const SUDO_INU_NFT = "0xa78c124b4f7368adde6a74d32ed9c369fe016f20";
const SNACK = "0x2b8a8845b9bbb8b5beef1d95ef6a60701d867142";
const XMON_SNACK_LP = "0x096c24c5bc54a2714d5db90ea46d8c4140aebe5d";

async function main() {
  const [deployer] = await ethers.getSigners();

  const buySpotPrice = ethers.utils.parseEther("0.05");
  const sellSpotPrice = ethers.utils.parseEther("0.1");

  const snackToken = await SnackToken__factory.connect(SNACK, deployer);

  // Wrapped ERC-721 as ERC-20
  const wrappedXminu = await new WrappedXminu__factory(deployer).deploy(
    SUDO_INU_NFT
  );
  await wrappedXminu.deployed();
  console.log("Wrapped XMINU ERC20: ", wrappedXminu.address);

  // Buy LP Token
  const sudoInuBuyWallLp = await new SudoInuLP__factory(deployer).deploy({
    nft: SUDO_INU_NFT,
    factory: FACTORY,
    curve: LINEAR_CURVE,
    poolType: PoolType.TOKEN,
    spotPrice: buySpotPrice,
    allowFractional: true,
  });
  await sudoInuBuyWallLp.deployed();
  console.log("Sudo INU Buy Wall LP: ", sudoInuBuyWallLp.address);

  // Sell LP Token
  const sudoInuHighFeeTradeLp = await new SudoInuLP__factory(deployer).deploy({
    nft: SUDO_INU_NFT,
    factory: FACTORY,
    curve: EXPONENTIAL_CURVE,
    poolType: PoolType.TRADE,
    spotPrice: sellSpotPrice,
    allowFractional: true,
  });
  await sudoInuHighFeeTradeLp.deployed();
  console.log("Sudo INU High Fee Sell LP: ", sudoInuHighFeeTradeLp.address);

  const sqrtMath = await new SqrtMath__factory(deployer).deploy();
  await sqrtMath.deployed();

  // Farm
  const snackShack = await new SnackShack__factory(
    { ["contracts/lib/SqrtMath.sol:SqrtMath"]: sqrtMath.address },
    deployer
  ).deploy(SNACK, deployer.address);
  await snackShack.deployed();
  console.log("Snack Shack Farm: ", snackShack.address);

  // Controllers
  const defaultController = await new DefaultController__factory(
    deployer
  ).deploy(snackShack.address);
  await defaultController.deployed();
  console.log("Default Controller: ", defaultController.address);

  const buyWallController = await new SudoController__factory(
    { ["contracts/lib/SqrtMath.sol:SqrtMath"]: sqrtMath.address },
    deployer
  ).deploy(
    snackShack.address,
    sudoInuBuyWallLp.address,
    0, // 0% fee
    0, // 0% delta
    buySpotPrice,
    ethers.utils.parseEther("0.0000001") // 0.0000001 delta per 1 ETH of liquidity
  );
  await buyWallController.deployed();
  console.log("Buy Wall Controller: ", buyWallController.address);

  const highFeeTradeController = await new SudoController__factory(
    { ["contracts/lib/SqrtMath.sol:SqrtMath"]: sqrtMath.address },
    deployer
  ).deploy(
    snackShack.address,
    sudoInuHighFeeTradeLp.address,
    ethers.utils.parseEther("0.06"), // 6% fee
    ethers.utils.parseEther("1.05"), // 5% delta
    sellSpotPrice,
    ethers.utils.parseEther("0.0000001") // 0.0000001 delta per 1 ETH of liquidity
  );
  await highFeeTradeController.deployed();
  console.log("Exponential Sell Controller: ", highFeeTradeController.address);

  await snackToken.transferOwnership(snackShack.address);
  console.log("Transferred SNACK ownership to Snack Shack Farm");

  await timeoutPromise(10000);

  await snackShack.add(
    1000,
    FarmType.STANDARD,
    XMON_SNACK_LP,
    ethers.constants.AddressZero,
    defaultController.address
  );
  console.log("PID 0: ", "XMON / SNACK LP UNI-V2");
  await timeoutPromise(10000);

  await snackShack.add(
    150,
    FarmType.STANDARD,
    wrappedXminu.address,
    ethers.constants.AddressZero,
    defaultController.address
  );
  console.log("PID 1: ", await wrappedXminu.name());
  await timeoutPromise(10000);

  await snackShack.add(
    150,
    FarmType.STANDARD,
    SNACK,
    ethers.constants.AddressZero,
    defaultController.address
  );
  console.log("PID 2: ", "SNACK");
  await timeoutPromise(10000);

  await snackShack.add(
    250,
    FarmType.SCALED,
    sudoInuBuyWallLp.address,
    ethers.constants.AddressZero,
    buyWallController.address
  );
  console.log("PID 3: ", await sudoInuBuyWallLp.name(), "BUY");
  await timeoutPromise(10000);

  await snackShack.add(
    100,
    FarmType.SCALED,
    sudoInuHighFeeTradeLp.address,
    ethers.constants.AddressZero,
    highFeeTradeController.address
  );
  console.log("PID 4: ", await sudoInuHighFeeTradeLp.name(), "SELL");
}

function timeoutPromise(timeout: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, timeout);
  });
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
