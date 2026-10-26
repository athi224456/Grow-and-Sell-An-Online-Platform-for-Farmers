import os, sqlite3, secrets
from functools import wraps
from flask import (Flask, g, render_template, request, redirect,
                   url_for, session, flash, abort)
from werkzeug.security import generate_password_hash, check_password_hash

BASE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(BASE, "growandsell.db")
CATEGORIES = ["Vegetables", "Fruits", "Grains", "Pulses", "Dairy", "Spices", "Other"]
STATUSES = ["Pending", "Accepted", "Shipped", "Delivered", "Cancelled"]

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "dev-change-me")


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB)
        g.db.row_factory = sqlite3.Row
    return g.db


@app.teardown_appcontext
def close_db(_):
    db = g.pop("db", None)
    if db:
        db.close()


def init_db():
    with sqlite3.connect(DB) as c:
        with open(os.path.join(BASE, "schema.sql")) as f:
            c.executescript(f.read())


def csrf_token():
    if "_csrf" not in session:
        session["_csrf"] = secrets.token_hex(16)
    return session["_csrf"]


app.jinja_env.globals["csrf_token"] = csrf_token


@app.before_request
def check_csrf():
    if request.method == "POST":
        if request.form.get("_csrf") != session.get("_csrf"):
            abort(400, "Invalid form token")


@app.before_request
def load_user():
    uid = session.get("uid")
    g.user = get_db().execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone() if uid else None


def login_required(role=None):
    def deco(fn):
        @wraps(fn)
        def wrap(*a, **kw):
            if not g.user:
                flash("Please log in first.", "warn")
                return redirect(url_for("login"))
            if role and g.user["role"] != role:
                abort(403)
            return fn(*a, **kw)
        return wrap
    return deco


@app.route("/")
def index():
    q = request.args.get("q", "").strip()
    cat = request.args.get("category", "")
    sql = ("SELECT p.*, u.name AS farmer, u.location FROM products p "
           "JOIN users u ON u.id=p.farmer_id WHERE p.quantity>0")
    args = []
    if q:
        sql += " AND (p.name LIKE ? OR u.location LIKE ?)"
        args += [f"%{q}%", f"%{q}%"]
    if cat:
        sql += " AND p.category=?"
        args.append(cat)
    sql += " ORDER BY p.created_at DESC"
    products = get_db().execute(sql, args).fetchall()
    return render_template("index.html", products=products, q=q, cat=cat, categories=CATEGORIES)


@app.route("/register", methods=["GET", "POST"])
def register():
    if request.method == "POST":
        f = request.form
        name, email, pw = f["name"].strip(), f["email"].strip().lower(), f["password"]
        role = f.get("role")
        if not (name and email and len(pw) >= 6 and role in ("farmer", "buyer")):
            flash("Fill all fields (password min 6 chars).", "error")
        else:
            try:
                db = get_db()
                db.execute("INSERT INTO users(name,email,password_hash,role,phone,location) VALUES(?,?,?,?,?,?)",
                           (name, email, generate_password_hash(pw), role,
                            f.get("phone", ""), f.get("location", "")))
                db.commit()
                flash("Account created. Please log in.", "ok")
                return redirect(url_for("login"))
            except sqlite3.IntegrityError:
                flash("Email already registered.", "error")
    return render_template("register.html")


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        u = get_db().execute("SELECT * FROM users WHERE email=?",
                             (request.form["email"].strip().lower(),)).fetchone()
        if u and check_password_hash(u["password_hash"], request.form["password"]):
            session.clear()
            session["uid"] = u["id"]
            return redirect(url_for("dashboard"))
        flash("Invalid email or password.", "error")
    return render_template("login.html")


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("index"))


@app.route("/dashboard")
@login_required()
def dashboard():
    db = get_db()
    if g.user["role"] == "farmer":
        products = db.execute("SELECT * FROM products WHERE farmer_id=? ORDER BY id DESC", (g.user["id"],)).fetchall()
        orders = db.execute(
            "SELECT o.*, p.name AS product, p.unit, u.name AS buyer, u.phone FROM orders o "
            "JOIN products p ON p.id=o.product_id JOIN users u ON u.id=o.buyer_id "
            "WHERE p.farmer_id=? ORDER BY o.id DESC", (g.user["id"],)).fetchall()
        return render_template("farmer_dashboard.html", products=products, orders=orders, statuses=STATUSES)
    orders = db.execute(
        "SELECT o.*, p.name AS product, p.unit, u.name AS farmer FROM orders o "
        "JOIN products p ON p.id=o.product_id JOIN users u ON u.id=p.farmer_id "
        "WHERE o.buyer_id=? ORDER BY o.id DESC", (g.user["id"],)).fetchall()
    return render_template("buyer_dashboard.html", orders=orders)


def parse_product_form(f):
    try:
        price, qty = float(f["price"]), float(f["quantity"])
        if price <= 0 or qty < 0:
            raise ValueError
    except (ValueError, KeyError):
        return None
    if f.get("category") not in CATEGORIES or not f.get("name", "").strip():
        return None
    return (f["name"].strip(), f["category"], price, f.get("unit", "kg").strip() or "kg",
            qty, f.get("description", "").strip())


@app.route("/products/new", methods=["GET", "POST"])
@login_required("farmer")
def product_new():
    if request.method == "POST":
        data = parse_product_form(request.form)
        if not data:
            flash("Please enter valid product details.", "error")
        else:
            db = get_db()
            db.execute("INSERT INTO products(farmer_id,name,category,price,unit,quantity,description) "
                       "VALUES(?,?,?,?,?,?,?)", (g.user["id"], *data))
            db.commit()
            flash("Product listed.", "ok")
            return redirect(url_for("dashboard"))
    return render_template("product_form.html", p=None, categories=CATEGORIES)


@app.route("/products/<int:pid>/edit", methods=["GET", "POST"])
@login_required("farmer")
def product_edit(pid):
    db = get_db()
    p = db.execute("SELECT * FROM products WHERE id=? AND farmer_id=?", (pid, g.user["id"])).fetchone()
    if not p:
        abort(404)
    if request.method == "POST":
        data = parse_product_form(request.form)
        if not data:
            flash("Please enter valid product details.", "error")
        else:
            db.execute("UPDATE products SET name=?,category=?,price=?,unit=?,quantity=?,description=? WHERE id=?",
                       (*data, pid))
            db.commit()
            flash("Product updated.", "ok")
            return redirect(url_for("dashboard"))
    return render_template("product_form.html", p=p, categories=CATEGORIES)


@app.route("/products/<int:pid>/delete", methods=["POST"])
@login_required("farmer")
def product_delete(pid):
    db = get_db()
    if db.execute("SELECT 1 FROM orders WHERE product_id=?", (pid,)).fetchone():
        db.execute("UPDATE products SET quantity=0 WHERE id=? AND farmer_id=?", (pid, g.user["id"]))
        flash("Product has orders, so it was marked out of stock instead of deleted.", "warn")
    else:
        db.execute("DELETE FROM products WHERE id=? AND farmer_id=?", (pid, g.user["id"]))
        flash("Product deleted.", "ok")
    db.commit()
    return redirect(url_for("dashboard"))


@app.route("/products/<int:pid>")
def product_detail(pid):
    p = get_db().execute(
        "SELECT p.*, u.name AS farmer, u.location, u.phone FROM products p "
        "JOIN users u ON u.id=p.farmer_id WHERE p.id=?", (pid,)).fetchone()
    if not p:
        abort(404)
    return render_template("product_detail.html", p=p)


@app.route("/products/<int:pid>/order", methods=["POST"])
@login_required("buyer")
def place_order(pid):
    db = get_db()
    p = db.execute("SELECT * FROM products WHERE id=?", (pid,)).fetchone()
    if not p:
        abort(404)
    try:
        qty = float(request.form["quantity"])
    except (ValueError, KeyError):
        qty = 0
    address = request.form.get("address", "").strip()
    if qty <= 0 or qty > p["quantity"] or not address:
        flash("Enter a valid quantity (within stock) and delivery address.", "error")
        return redirect(url_for("product_detail", pid=pid))
    db.execute("INSERT INTO orders(product_id,buyer_id,quantity,total,address) VALUES(?,?,?,?,?)",
               (pid, g.user["id"], qty, round(qty * p["price"], 2), address))
    db.execute("UPDATE products SET quantity=quantity-? WHERE id=?", (qty, pid))
    db.commit()
    flash("Order placed!", "ok")
    return redirect(url_for("dashboard"))


@app.route("/orders/<int:oid>/status", methods=["POST"])
@login_required("farmer")
def order_status(oid):
    status = request.form.get("status")
    db = get_db()
    o = db.execute("SELECT o.*, p.farmer_id FROM orders o JOIN products p ON p.id=o.product_id WHERE o.id=?",
                   (oid,)).fetchone()
    if not o or o["farmer_id"] != g.user["id"] or status not in STATUSES:
        abort(404)
    if status == "Cancelled" and o["status"] != "Cancelled":
        db.execute("UPDATE products SET quantity=quantity+? WHERE id=?", (o["quantity"], o["product_id"]))
    db.execute("UPDATE orders SET status=? WHERE id=?", (status, oid))
    db.commit()
    flash("Order updated.", "ok")
    return redirect(url_for("dashboard"))


if __name__ == "__main__":
    init_db()
    app.run(debug=True)
