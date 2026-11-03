# Jinja

A Swift implementation of the
[Jinja2 template engine](https://jinja.palletsprojects.com/en/3.1.x/).

Jinja templates are widely used for generating HTML, configuration files, code generation, and text processing.
This implementation is focused primarily on the features needed to generate LLM chat templates.

## Requirements

- Swift 6.0+ / Xcode 16+

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/huggingface/swift-jinja.git", from: "2.0.0")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "Jinja", package: "swift-jinja")
    ]
)
```

## Features

This package implements a subset of the functionality of the
[official Python implementation](https://jinja.palletsprojects.com/en/stable/templates/).

### Supported Features ✅

- **Variables**:
  `{{ variable }}`, `{{ object.attribute }}`, `{{ dict['key'] }}`
- **Comments**:
  `{# comment #}`
- **Statements**:
  `{% statement %}`
- **Value Types**:
  Boolean (`true`, `false`),
  integers (`42`),
  floats (`3.14`),
  strings (`"hello"`),
  arrays (`[1, 2, 3]`),
  objects (`{"key": "value"}`), and
  null (`null`)
- **Arithmetic Operators**:
  `+`, `-`, `*`, `/`,
  `//` (floor division),
  `**` (exponentiation),
  `%`
- **String Concatenation Operators**:
  `~`
  and automatic concatenation of adjacent string literals
- **Comparison Operators**:
  `==`, `!=`, `<`, `<=`, `>`, `>=`
- **Logical Operators**:
  `and`, `or`, `not`
- **Membership Operator**:
  `in`
- **Attribute Access**:
  `.` and `[]`
- **Conditionals**:
  `{% if %}`, `{% elif %}`, `{% else %}`, `{% endif %}`
- **Loops**:
  `{% for item in list %}...{% endfor %}`
- **Loop Variables**:
  `loop.index`, `loop.index0`, `loop.first`, `loop.last`, `loop.length`
- **Loop Filtering**:
  `{% for item in list if condition %}`
- **Loop Controls**:
  `{% break %}`, `{% continue %}`
- **Variable Assignment**:
  `{% set variable = value %}`
- **Macros**:
  `{% macro name() %}...{% endmacro %}`
- **Macro Calls**:
  `{% call macro_name() %}`
- **Filter Statements**:
  `{{ name | upper }}`
- **Filter Blocks**:
  `{% filter upper %}...{% endfilter %}`
- **Generation Blocks**:
  `{% generation %}...{% endgeneration %}`
  (Hugging Face extension for marking assistant-generated content)
- **Tests**:
  `is` operator for type/value checks (e.g. `{% if value is number %}`)
- **Global Functions**:
  `range()`, `lipsum()`, `dict()`, `cycler()`, `joiner()`, `namespace()`, `strftime_now()`
- **Exception Handling**:
  `raise_exception()` (throws `Exception` error)

<details>

<summary>Supported Filters</summary>

- [x] `abs()`
- [x] `attr()`
- [x] `batch()`
- [x] `capitalize()`
- [x] `center()`
- [x] `default()`
- [x] `dictsort()`
- [x] `escape()`
- [x] `filesizeformat()`
- [x] `first()`
- [x] `float()`
- [x] `forceescape()`
- [x] `format()`
- [x] `groupby()`
- [x] `indent()`
- [x] `int()`
- [x] `items()`
- [x] `join()`
- [x] `last()`
- [x] `length()`
- [x] `list()`
- [x] `lower()`
- [x] `map()`
- [x] `max()`
- [x] `min()`
- [x] `pprint()`
- [x] `random()`
- [x] `reject()`
- [x] `rejectattr()`
- [x] `replace()`
- [x] `reverse()`
- [x] `round()`
- [x] `safe()`
- [x] `select()`
- [x] `selectattr()`
- [x] `slice()`
- [x] `sort()`
- [x] `string()`
- [x] `striptags()`
- [x] `sum()`
- [x] `title()`
- [x] `tojson()`
- [x] `trim()`
- [x] `truncate()`
- [x] `unique()`
- [x] `upper()`
- [x] `urlencode()`
- [x] `urlize()`
- [x] `wordcount()`
- [x] `wordwrap()`
- [x] `xmlattr()`

</details>

<details>

<summary>Supported tests</summary>

- [x] `boolean()`
- [x] `callable()`
- [x] `defined()`
- [x] `divisibleby()`
- [x] `eq()`
- [x] `escaped()`
- [x] `even()`
- [x] `false()`
- [x] `filter()`
- [x] `float()`
- [x] `ge()`
- [x] `gt()`
- [x] `in()`
- [x] `integer()`
- [x] `iterable()`
- [x] `le()`
- [x] `lower()`
- [x] `lt()`
- [x] `mapping()`
- [x] `ne()`
- [x] `none()`
- [x] `number()`
- [x] `odd()`
- [x] `sameas()`
- [x] `sequence()`
- [x] `string()`
- [x] `test()`
- [x] `true()`
- [x] `undefined()`
- [x] `upper()`

</details>

### Not Supported Features ❌

- **Template Inheritance**:
  `{% extends %}` and `{% block %}`
- **Template Includes**:
  `{% include %}`
- **Template Imports**:
  `{% import %}`, `{% from ... import %}`
- **Block Inheritance**:
  `super()`, block scoping, required blocks
- **With Statement**:
  `{% with %}` for variable scoping
- **Raw Blocks**:
  `{% raw %}...{% endraw %}`
- **Internationalization**:
  `{% trans %}`, `{% pluralize %}`, `i18n` extension
- **Debug Statement**:
  `{% debug %}`
- **Do Statement**:
  `{% do expression %}` (expression without output)
- **Autoescape**:
  `{% autoescape %}`
  blocks and automatic HTML escaping
- **Line Statements**:
  Alternative syntax with prefix characters (`# for item in seq` instead of `{% for item in seq %}`)
- **Extensions**:
  Custom extensions that add extra functionality at the parser level are not supported.
  If you need features beyond custom tests, filters, or macros,
  fork the package and implement changes directly.

## Usage

### Basic Template Rendering

```swift
import Jinja

// Create and render a simple template
let template = try Template("Hello, {{ name }}!")
let result = try template.render(["name": "World"])
print(result) // "Hello, World!"
```

### Template with Context Variables

```swift
// Template with multiple variables
let template = try Template("""
    Welcome, {{ user.name }}!
    You have {{ messages | length }} new messages.
    """)

let context: [String: Value] = [
    "user": ["name": "Alice"],
    "messages": [
        "Hello",
        "How are you?",
        "See you later"
    ]
]

let result = try template.render(context)
// "Welcome, Alice!\nYou have 3 new messages."
```

> [!IMPORTANT]  
> **Migrating to Jinja v2.0**:
> Most code using Jinja v1 should work with v2 with minimal changes.
> The biggest breaking change is that the context parameter for rendering templates
> has changed from `[String: Any]` to `[String: Value]`.
>
> Thanks to `Value` being expressible by literals,
> existing code may work as-is.
> You can also try the `Value(any:)` constructor
> to automatically convert complex values:
>
> ```swift
> // Create template and context
> let template = try Template("Hello {{ user.name }}!")
>
> var context: [String: Value] = [
>     // Use literals:
>     "user": ["name": "Alice"],
> ]
>
> // ...or convert from Any value:
> let settings: [String: Any] = ["theme": "dark", "notifications": true]
> context["settings"] = try Value(any: settings)
>
> let result = try template.render(context)
> // "Hello Alice!"
> ```

### Control Flow

```swift
// Conditional rendering
let template = try Template("""
    {% for item in items %}
        {% if item.active %}
            * {{ item.name }} ({{ item.price }})
        {% endif %}
    {% endfor %}
    """)

let context: [String: Value] = [
    "items": [
        [
            "name": "Coffee",
            "price": 4.50,
            "active": true
        ],
        [
            "name": "Tea",
            "price": 3.25,
            "active": false
        ]
    ]
]

let result = try template.render(context)
// "    * Coffee (4.5)\n"
```

### Built-in Filters

Templates support Jinja
[built-in filters](https://jinja.palletsprojects.com/en/stable/templates/#jinja-filters)
for data transformation and manipulation.

```swift
// String manipulation filters
let template = try Template("""
    {{ name | upper }}
    {{ description | truncate(50) }}
    {{ tags | join(", ") }}
    """)

let context: [String: Value] = [
    "name": "swift package",
    "description": "A powerful template engine for Swift applications",
    "tags": ["swift", "templates", "web"]
]

let result = try template.render(context)
```

### Tests

Jinja provides
[built-in tests](<(https://jinja.palletsprojects.com/en/stable/templates/#list-of-builtin-tests)>)
for conditional logic and type checking.
Tests are used with the `is` operator to evaluate conditions in templates.
These tests help you make decisions based on the
type, value, or properties of variables.

```swift
// Type and value checking with tests
let template = try Template("""
    {% if user is defined %}
        Welcome, {{ user.name }}!
    {% else %}
        Please log in.
    {% endif %}

    {% if messages is iterable and messages | length > 0 %}
        You have {{ messages | length }} messages.
    {% endif %}

    {% if age is number and age >= 18 %}
        You are an adult.
    {% elif age is number and age < 18 %}
        You are a minor.
    {% endif %}

    {% if status is none %}
        Status not set.
    {% elif status is true %}
        Active
    {% elif status is false %}
        Inactive
    {% endif %}
    """)

let context: [String: Value] = [
    "user": ["name": "Alice"],
    "messages": ["Hello", "How are you?"],
    "age": 25,
    "status": true
]

let result = try template.render(context)
// "Welcome, Alice!\nYou have 2 messages.\nYou are an adult.\nActive"
```

### Template Options

```swift
// Configure template behavior
let options = Template.Options(
    lstripBlocks: true,  // Strip leading whitespace from blocks
    trimBlocks: true     // Remove trailing newlines from blocks
)

let template = try Template("""
    {% for item in items %}
        {{ item }}
    {% endfor %}
    """, with: options)
```

### Value Types

The `Value` enum represents all possible template values:

```swift
// Creating values directly
let context: [String: Value] = [
    "text": "Hello",
    "number": 42,
    "decimal": 3.14,
    "flag": true,
    "items": ["a", "b"],
    "user": ["name": "John", "age": 30],
    "missing": .null
]

// ...or from Swift types
let swiftValue: Any? = ["name": "John", "items": [1, 2, 3]]
let jinjaValue = try Value(any: swiftValue)
```

## Examples

### HTML Generation

```swift
import Jinja

// Generate HTML from template
let htmlTemplate = try Template("""
    <!DOCTYPE html>
    <html>
    <head>
        <title>{{ page.title }}</title>
    </head>
    <body>
        <h1>{{ page.heading }}</h1>
        <ul>
        {% for item in page.items %}
            <li><a href="{{ item.url }}">{{ item.title }}</a></li>
        {% endfor %}
        </ul>
    </body>
    </html>
    """)

let context: [String: Value] = [
    "page": [
        "title": "My Website",
        "heading": "Welcome",
        "items": .array([
            ["title": "Home", "url": "/"),
            ["title": "About", "url": "/about"],
            ["title": "Contact", "url": "/contact"]
        ]
    ]
]

let html = try htmlTemplate.render(context)
```

### Configuration File Generation

```swift
// Generate configuration files
let configTemplate = try Template("""
    # {{ app.name }} Configuration

    [server]
    host = "{{ server.host }}"
    port = {{ server.port }}
    debug = {{ server.debug | lower }}

    [database]
    {% for db in databases %}
    [database.{{ db.name }}]
    url = "{{ db.url }}"
    pool_size = {{ db.pool_size }}
    {% endfor %}
    """)

let context: [String: Value] = [
    "app": ["name": "MyApp"],
    "server": [
        "host": "localhost",
        "port": 8080,
        "debug": true
    ],
    "databases": [
        [
            "name": "primary",
            "url": "postgresql://localhost/myapp",
            "pool_size": 10
        ]
    ]
]

let config = try configTemplate.render(context)
```

### Chat Message Formatting

```swift
// Format chat messages (useful for AI/LLM applications)
let chatTemplate = try Template("""
    {% for message in messages %}
        {% if message.role == "system" %}
            System: {{ message.content }}
        {% elif message.role == "user" %}
            User: {{ message.content }}
        {% elif message.role == "assistant" %}
            Assistant: {{ message.content }}
        {% endif %}
    {% endfor %}
    """, with: Template.Options(lstripBlocks: true, trimBlocks: true))

let messages: [String: Value] = [
    "messages": [
        [
            "role": "system",
            "content": "You are a helpful assistant."
        ],
        [
            "role": "user",
            "content": "What's the weather like?"
        ],
        [
            "role": "assistant",
            "content": "I'd be happy to help with weather information!"
        ]
    ]
]

let formatted = try chatTemplate.render(messages)
```

## Contributing

This is a community project and we welcome contributions.
Please check out
[Issues tagged with `good first issue`][good-first-issues]
if you are looking for a place to start!

Please ensure your code passes the build and test suite
before submitting a pull request.
You can run the tests with `swift test`.

[good-first-issues]: https://github.com/huggingface/swift-jinja/issues?q=is%3Aissue%20state%3Aopen%20label%3A%22good%20first%20issue%22

## License

[Apache 2](LICENSE).
