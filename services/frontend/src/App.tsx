import { useCallback, useEffect, useState } from "react";
import { createOrder, fetchOrders, fetchProducts, type Order, type Product } from "./api";

export default function App() {
  const [products, setProducts] = useState<Product[]>([]);
  const [orders, setOrders] = useState<Order[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [pendingId, setPendingId] = useState<string | null>(null);

  const loadProducts = useCallback(async () => {
    try {
      setProducts(await fetchProducts());
    } catch (err) {
      setError((err as Error).message);
    }
  }, []);

  const loadOrders = useCallback(async () => {
    try {
      setOrders(await fetchOrders());
    } catch (err) {
      setError((err as Error).message);
    }
  }, []);

  useEffect(() => {
    void loadProducts();
    void loadOrders();
  }, [loadProducts, loadOrders]);

  const handleOrder = async (productId: string) => {
    setPendingId(productId);
    setError(null);
    try {
      await createOrder(productId, 1);
      await loadOrders();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setPendingId(null);
    }
  };

  return (
    <div className="app">
      <header className="app-header">
        <h1>ZTD Storefront</h1>
      </header>

      {error && <div className="banner banner-error">{error}</div>}

      <section>
        <h2>Products</h2>
        <div className="product-grid">
          {products.map((product) => (
            <div className="product-card" key={product.id}>
              <h3>{product.name}</h3>
              <p className="price">${product.price.toFixed(2)}</p>
              <p className="stock">{product.stock} in stock</p>
              <button
                type="button"
                disabled={pendingId === product.id || product.stock === 0}
                onClick={() => handleOrder(product.id)}
              >
                {pendingId === product.id ? "Ordering..." : "Order 1"}
              </button>
            </div>
          ))}
          {products.length === 0 && <p>No products available.</p>}
        </div>
      </section>

      <section>
        <h2>Orders</h2>
        <table className="orders-table">
          <thead>
            <tr>
              <th>ID</th>
              <th>Product</th>
              <th>Qty</th>
              <th>Status</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            {orders.map((order) => (
              <tr key={order.id}>
                <td>{order.id}</td>
                <td>{order.productId}</td>
                <td>{order.quantity}</td>
                <td>{order.status}</td>
                <td>{order.createdAt}</td>
              </tr>
            ))}
            {orders.length === 0 && (
              <tr>
                <td colSpan={5}>No orders yet.</td>
              </tr>
            )}
          </tbody>
        </table>
      </section>
    </div>
  );
}
