# thp

thp, or **t**iny **h**ypertext **p**reprocessor, is a tool that helps you write
small static websites with Lua.

```html
<ul>
  <?lua
  for i = 1, 10 do
    echo('<li>' .. i .. '</li>')
  end
  ?>
</ul>
```

The example above creates a list of numbers 1 to 10.

## Usage

Create an HTML file. Anything surrounding `<?lua` and `?>` will be executed as
Lua code. To run thp, you can run any of the following:

- `thp serve <directory> [address]` runs a local server for the given directory.
- `thp build <file>` builds a single file and displays it to stdout.
- `thp build_dir <src> <dst>` builds all files in `src` and writes the results
  to `dst`. Any files that start with an underscore are not written to `dst`.

In addition to the standard Lua libraries, thp introduces two new functions:

- `echo` outputs a string.
- `import` includes a file. If the file ends in `.html`, it will run the
  preprocessor. Otherwise, the file is treated as a `.lua` file in the same
  manner as `require`.

Because `require` only loads a file once, you'll probably want to use `import`
over `require`, to make sure everything gets executed per HTTP request.

## Examples

Below, `index.html` and `about.html` shares the same HTML skeleton provided by
`_base.html`.

```html
<!-- _base.html -->
<?lua

function document(body)
  ?>
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <title>My Awesome Site</title>
  </head>
  <body>
    <nav>
      <ul>
        <li><a href="/">Home</a></li>
        <li><a href="/about.html">About</a></li>
      </ul>
    </nav>
    <?lua body() ?>
  </body>
  </html>
  <?lua
end

?>
```

```html
<!-- index.html -->
<?lua

import '_baseof.html'

document(function()
  ?>
  <h1>Homepage</h1>
  <?lua
end)

?>
```

```html
<!-- about.html -->
<?lua

import '_baseof.html'

document(function()
  ?>
  <h1>About</h1>
  <p>
    Lorem, ipsum dolor sit amet consectetur adipisicing elit. Asperiores id
    sed earum corporis quaerat. Sed possimus placeat ea obcaecati omnis?
    Minima, hic aliquid qui delectus ullam iste, provident numquam nam?
  </p>
  <?lua
end)

?>
```

You can create a lua file that contains some data, then import that data in an
HTML file.

```lua
-- _products.lua

return {
  {
    name = "T-Shirt",
    price = "29.99 CAD",
    quantity = 40,
  },
  {
    name = "Jacket",
    price = "79.99 CAD",
    quantity = 30,
  },
  {
    name = "Scarf",
    price = "23.99 CAD",
    quantity = 33,
  },
}
```

```html
<!-- store.html -->
<?lua

local products = import '_products.lua'

for i, product in ipairs(products) do
  ?>
  <div>
    <h2><?lua echo(product.name) ?></h2>
    <p>Price: <?lua echo(product.price) ?></p>
    <p>Quantity: <?lua echo(product.quantity) ?></p>
  </div>
  <?lua
end

?>
```