import { test } from "node:test";
import assert from "node:assert/strict";
import { average } from "../src/average.js";

test("average of several numbers", () => {
  assert.equal(average([2, 4, 6]), 4);
});
