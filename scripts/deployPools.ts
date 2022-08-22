import { ethers } from "hardhat";

import {
  DefaultController__factory,
  SudoController__factory,
  SudoInuLP__factory,
  SudoInu__factory,
  SnackToken__factory,
  SnackShack__factory,
  WrappedXminu__factory,
  MockERC20__factory,
} from "../typechain";

enum FarmType {
  STANDARD = 0,
  SCALED = 1,
}

async function main() {
  const [deployer] = await ethers.getSigners();

  const buySpotPrice = ethers.utils.parseEther("0.0005");
  const sellSpotPrice = ethers.utils.parseEther("0.001");

  // Mock ERC-20
  const fakeSnackXmonLpToken = await MockERC20__factory.connect(
    "0xEf5063258dfB423CFba0c1Dd0A9672CF6388fa5d",
    deployer
  );

  const fakeXmonToken = await MockERC20__factory.connect(
    "0x2e87034AdC9fa3e70422BF3b3191258D1313C3e5",
    deployer
  );

  // ERC-20
  const snackToken = await SnackToken__factory.connect(
    "0xDf3BBC576Aeb39A6eD1FCe32e89b4c81621F350D",
    deployer
  );

  // ERC-721
  const xminuNft = await SudoInu__factory.connect(
    "0x58D70a2bc56669d58126c2b564512BFD10cf1463",
    deployer
  );

  // Wrapped ERC-721 as ERC-20
  const wrappedXminu = await WrappedXminu__factory.connect(
    "0xF0Cf0F2A90996DF25ddfa9683cB5B20Ab6496d37",
    deployer
  );

  // Buy LP Token
  const sudoInuBuyWallLp = await SudoInuLP__factory.connect(
    "0x44F2AdB5E368F8B71614687d5B133e9eb53783F1",
    deployer
  );

  // Sell LP Token
  const sudoInuExpSellLp = await SudoInuLP__factory.connect(
    "0xF4C7cDA99042983b72C2BF5182118c2c5ec40cCA",
    deployer
  );

  // Farm
  const snackShack = await SnackShack__factory.connect(
    "0x16EBDCf76cc605390ba460970eAe398f1f1759CE",
    deployer
  );

  // Controllers
  const buyWallController = await SudoController__factory.connect(
    "0xfC7b3A5f08669f63fc27421Bc7388D40ed715bd3",
    deployer
  );

  const expSellController = await SudoController__factory.connect(
    "0xEd4BE662c7c042CaEF7A926BD46A5905dbEC56FE",
    deployer
  );

  // await snackShack.add(
  //   1000,
  //   FarmType.STANDARD,
  //   fakeSnackXmonLpToken.address,
  //   ethers.constants.AddressZero,
  //   defaultController.address
  // );
  // console.log("PID 0: ", await fakeSnackXmonLpToken.name());
  // await timeoutPromise(2500);

  // await fakeSnackXmonLpToken.mint(
  //   deployer.address,
  //   ethers.utils.parseEther("10")
  // );
  // console.log("Minted: ", await fakeSnackXmonLpToken.name());
  // await timeoutPromise(2500);

  // await snackShack.add(
  //   100,
  //   FarmType.STANDARD,
  //   fakeXmonToken.address,
  //   ethers.constants.AddressZero,
  //   defaultController.address
  // );
  // console.log("PID 1: ", await fakeXmonToken.name());
  // await timeoutPromise(2500);

  // await fakeXmonToken.mint(deployer.address, ethers.utils.parseEther("10"));
  // console.log("Minted: ", await fakeXmonToken.name());
  // await timeoutPromise(2500);

  // await snackShack.add(
  //   150,
  //   FarmType.STANDARD,
  //   wrappedXminu.address,
  //   ethers.constants.AddressZero,
  //   defaultController.address
  // );
  // console.log("PID 2: ", await wrappedXminu.name());
  // await timeoutPromise(2500);

  // await xminuNft.mint();
  // console.log("Minted: ", await wrappedXminu.name());
  // await timeoutPromise(2500);

  // await snackShack.add(
  //   150,
  //   FarmType.SCALED,
  //   snackToken.address,
  //   ethers.constants.AddressZero,
  //   defaultController.address
  // );
  // console.log("PID 3: ", await snackToken.name());
  // await timeoutPromise(2500);

  await snackShack.add(
    250,
    FarmType.SCALED,
    sudoInuBuyWallLp.address,
    ethers.constants.AddressZero,
    buyWallController.address
  );
  console.log("PID 4: ", await sudoInuBuyWallLp.name(), "BUY");
  await timeoutPromise(2500);

  await snackShack.add(
    250,
    FarmType.SCALED,
    sudoInuExpSellLp.address,
    ethers.constants.AddressZero,
    expSellController.address
  );
  console.log("PID 5: ", await sudoInuExpSellLp.name(), "SELL");
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
