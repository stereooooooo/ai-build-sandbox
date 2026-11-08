import { createServer } from "node:http";
import { sum } from "./sum.js";

const port = Number(process.env.PORT || 3100);
createServer((req, res) => res.end("sandbox ok " + sum(1, 2) + "\n"))
  .listen(port, () => console.log("listening on " + port));
