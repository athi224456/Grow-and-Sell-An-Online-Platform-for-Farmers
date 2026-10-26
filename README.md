Grow and Sell — An Online Platform for Farmers
A Flask + SQLite web app where farmers list produce directly and buyers browse, search and order.
Features
Farmer / buyer registration and login (hashed passwords, CSRF protection)
Farmers: add, edit, delete products; view incoming orders; update order status
Buyers: search and filter by category/location, place orders, track status
Stock auto-decrements on order and is restored on cancellation
Run
    pip install -r requirements.txt
    python seed.py      # optional demo data (farmer@demo.com / buyer@demo.com, password demo123)
    python app.py       # http://127.0.0.1:5000

Structure
    app.py        routes and logic
    schema.sql    database tables (users, products, orders)
    seed.py       demo data
    templates/    Jinja2 pages
    static/       CSS

Set SECRET_KEY env var in production and disable debug mode.
