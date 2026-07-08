package main

// Product represents a catalog item.
type Product struct {
	ID    string  `json:"id"`
	Name  string  `json:"name"`
	Price float64 `json:"price"`
	Stock int     `json:"stock"`
}

// seedProducts is the in-memory product catalog. Ids p1..p5 are stable and
// depended on by the orders service tests.
var seedProducts = []Product{
	{ID: "p1", Name: "Wireless Mouse", Price: 19.99, Stock: 150},
	{ID: "p2", Name: "Mechanical Keyboard", Price: 89.99, Stock: 75},
	{ID: "p3", Name: "USB-C Hub", Price: 34.50, Stock: 200},
	{ID: "p4", Name: "27-inch Monitor", Price: 249.00, Stock: 40},
	{ID: "p5", Name: "Webcam 1080p", Price: 45.25, Stock: 120},
}

// findProduct looks up a product by id. The second return value reports
// whether it was found.
func findProduct(id string) (Product, bool) {
	for _, p := range seedProducts {
		if p.ID == id {
			return p, true
		}
	}
	return Product{}, false
}
