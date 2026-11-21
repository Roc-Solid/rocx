const { prepare, client } = await import(process.argv[2]);
prepare({ dev: false });
console.log("client copy:", client);
