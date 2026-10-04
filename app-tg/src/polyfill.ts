// @ton/core uses Node's Buffer; provide it in the browser before @ton/core loads.
// This module MUST be imported first (see main.tsx).
import { Buffer } from "buffer";

(globalThis as unknown as { Buffer: typeof Buffer }).Buffer = Buffer;
