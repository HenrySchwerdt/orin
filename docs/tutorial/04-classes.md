# 4. Classes, interfaces and generics

## The program

<!-- file: examples/tutorial/04-classes.or -->
```ts
// Classes, interfaces and generics.
interface Shape {
  area(): int;
  name(): string;
}

class Square implements Shape {
  constructor(public side: int) {}
  area(): int { return this.side * this.side; }
  name(): string { return "square"; }
}

class Rect implements Shape {
  constructor(public w: int, public h: int) {}
  area(): int { return this.w * this.h; }
  name(): string { return "rect"; }
}

class Counter {
  constructor(public value: int) {}
  increment(): void { this.value += 1; }   // assigns to this: a mutating method
}

function describe(s: Shape): string {
  return s.name() + " with area " + s.area().toString();
}

function totalArea<T extends Shape>(items: T[]): int {
  let total = 0;
  for (const it of items) {
    total += it.area();
  }
  return total;
}

type Pair<A, B> = { first: A; second: B; };

function swap<A, B>(p: Pair<A, B>): Pair<B, A> {
  return Pair<B, A> { first: p.second, second: p.first };
}

function largest<T extends Ord>(a: T, b: T): T {
  return a > b ? a : b;
}

function main(): void {
  console.log(describe(new Square(3)));
  console.log(describe(new Rect(2, 5)));
  console.log("total: " + totalArea([new Square(1), new Square(2)]).toString());

  let a = new Counter(0);
  const b = a;             // b is an independent copy
  a.increment();
  a.increment();
  console.log("a = " + a.value.toString() + ", b = " + b.value.toString());

  const swapped = swap(Pair<int, string> { first: 1, second: "one" });
  console.log(swapped.first + " / " + swapped.second.toString());
  console.log("largest: " + largest(3, 9).toString() + " " + largest("pear", "apple"));
}
```

Output:

<!-- file: examples/tutorial/04-classes.out -->
```text
square with area 9
rect with area 10
total: 5
a = 2, b = 0
one / 1
largest: 9 pear
```

## What is in it

**Classes** have fields, a constructor and methods. `constructor(public side: int) {}` declares a public field and
assigns it. A class is used with `new Square(3)`. There is no inheritance: `class B extends A` is an error. Share behaviour
with interfaces and composition.

**Values, not references.** `const b = a;` copies. After `a.increment()` twice, `a` is `2` and `b` is still `0`. Nothing is
shared between variables, so there is never a question of who else holds the object. (The compiler copies lazily, so this
is cheap.)

**Mutation needs `let`.** A method that assigns to `this`, like `increment`, is *mutating*; the compiler works that out. You
can call it only on a variable declared with `let`; on a `const` it is an error. Function parameters are never mutable: a
function returns a changed copy instead of changing its argument.

**Interfaces** list methods. A class says `implements Shape`; conformance is declared, never guessed from the shape of the
class. `describe(s: Shape)` accepts any class that implements the interface.

**Generics.** `Pair<A, B>` is a generic record, `swap<A, B>` a generic function. Type arguments are usually inferred at the
call; a record literal of a generic type names them: `Pair<int, string> { ... }`. A bound limits what a type parameter may
be: `T extends Shape` allows calling `area()` on the items, `T extends Ord` allows `>` (the integers, strings and any
type with a derived or declared ordering qualify). Generic code is compiled once per type used, so it costs nothing at run
time.

## Try it

Add a `Circle` class with a `radius` and `implements Shape`, and pass it to `describe`. Then remove `implements Shape` from
`Rect` and read the error: conformance is nominal.

Reference: [classes, interfaces and generics](../reference/03-types.md), [ownership and mutation](../reference/05-ownership-resources-capabilities.md).

Next: [5. Collections and strings](05-collections.md).
