export interface Product {
  id: string;
  name: string;
  price: number;
  stock: number;
}

export interface Order {
  id: string;
  productId: string;
  quantity: number;
  status: string;
  createdAt: string;
}

async function handleResponse<T>(res: Response): Promise<T> {
  if (!res.ok) {
    throw new Error(`request failed: ${res.status}`);
  }
  return (await res.json()) as T;
}

export async function fetchProducts(): Promise<Product[]> {
  const res = await fetch("/api/products");
  return handleResponse<Product[]>(res);
}

export async function fetchOrders(): Promise<Order[]> {
  const res = await fetch("/api/orders");
  return handleResponse<Order[]>(res);
}

export async function createOrder(productId: string, quantity: number): Promise<Order> {
  const res = await fetch("/api/orders", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ productId, quantity }),
  });
  return handleResponse<Order>(res);
}
