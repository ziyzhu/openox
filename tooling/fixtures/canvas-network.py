from datetime import datetime
from mitmproxy import http


class CanvasNetwork:
    signed_in = False

    def request(self, flow):
        host = flow.request.host
        path = flow.request.path.split("?")[0]
        body = None
        if host == "github.com":
            if path == "/canvas-test/authorize":
                self.signed_in = True
            if path == "/canvas-test/reset":
                self.signed_in = False
            if path == "/login":
                body = '<h1>Fixture sign-in</h1><p>No real account is used.</p><a href="/canvas-test/authorize">Complete fixture sign-in</a>'
            elif path in ["/", "/canvas-test/authorize", "/canvas-test/reset"]:
                login = '<meta name="user-login" content="canvas-fixture">' if self.signed_in else ""
                body = login + '<h1>Fixture account</h1>'
        if host == "my.pacificsciencecenter.org":
            if path in ["/events", "/cart/details"]:
                body = '<h1>Fixture ticket cart</h1>'
            elif path == "/components/precart":
                body = '<h1>Fixture checkout</h1><p>No order or charge will be created.</p><a href="/cart/receipt/424242">Complete fixture checkout</a>'
            elif path == "/cart/receipt/424242":
                date = datetime.now().astimezone().isoformat()
                body = f'''<h1>Fixture receipt</h1><div class="tn-order-number">424242</div>
                    <div class="tn-order-date">Order Date: {date}</div>
                    <div class="tn-cart-item"><span class="tn-cart-line-item-name">Fixture ticket</span></div>
                    <span class="tn-cart-totals__value--total">$0.00</span>
                    <script>localStorage.setItem("ox.pacificsciencecenter.latestReceipt", "424242|{date}")</script>'''
        if body is None:
            flow.response = http.Response.make(503, b"Unmatched canvas test request")
        else:
            html = '<meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:20px system-ui;padding:24px}a{display:block;padding:24px}</style>' + body
            flow.response = http.Response.make(200, html.encode(), {"content-type": "text/html", "cache-control": "no-store"})


addons = [CanvasNetwork()]
