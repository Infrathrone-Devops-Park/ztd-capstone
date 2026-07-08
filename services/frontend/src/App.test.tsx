import { render, screen, waitFor } from "@testing-library/react";
import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";
import App from "./App";

describe("App", () => {
  beforeEach(() => {
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL) => {
        const url = typeof input === "string" ? input : input.toString();
        if (url.startsWith("/api/products")) {
          return Promise.resolve(
            new Response(
              JSON.stringify([
                { id: "p1", name: "Widget", price: 9.99, stock: 10 },
                { id: "p2", name: "Gadget", price: 19.99, stock: 5 },
              ]),
              { status: 200, headers: { "content-type": "application/json" } }
            )
          );
        }
        if (url.startsWith("/api/orders")) {
          return Promise.resolve(
            new Response(JSON.stringify([]), {
              status: 200,
              headers: { "content-type": "application/json" },
            })
          );
        }
        return Promise.reject(new Error(`unexpected fetch: ${url}`));
      })
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders the product list from GET /api/products", async () => {
    render(<App />);

    await waitFor(() => {
      expect(screen.getByText("Widget")).toBeInTheDocument();
      expect(screen.getByText("Gadget")).toBeInTheDocument();
    });

    expect(fetch).toHaveBeenCalledWith("/api/products");
  });
});
