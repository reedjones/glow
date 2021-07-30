This document proposes designs for future Glow compiler development,
with the goals of making Glow portable across multiple targets,
including EVM, Plutus Core, and possible other targets including
low-level virtual machines such as LLVM and WASM, and real hardware
ISAs such as RISC-V.

In particular, this document proposes:

- A low-level memory model and associated IR to be used when targeting
  lower-level machine-like platforms
- A higher-level IR, used in translating Glow to Plutus Core, but also
  as an intermediate step before the low level IR.

Where applicable, the document explores alternative design choices and
possible longer-term directions.

# Background And Design Considerations

Right now, all Glow code goes through several translation phases
culminating in the 'project' phase, which emits separate code for
each participant in an interaction, and for the consensus. This code is
then either interpreted (by the participants at runtime) or compiled
to EVM bytecode (by the consensus-code-generator) and run on the
blockchain.

Some salient properties of code emitted from `project` include:

- The code is in ANF; there are no complex expressions.
- Most semantically complex Glow-specific constructs (such as `verify!`)
  have been compiled out, with only more imperative constructs (such as
  `require!`) remaining. `withdraw!` and `deposit!` are still abstract
  operations.
- Participant changes happen via an imperative set-participant operation,
  rather than a declarative annotation on a set of statements.

It is somewhat ambiguous as to whether this form is closer to our low or
high level targets. Glow still lacks many of the features that would force
a distinction; we have no heap allocation and no recursion, so much of the
low level plumbing that might or might not be explicit is simply not
applicable. As the language evolves, we will have to decide where along
the translation path these become explicit. This proposal takes the
position that this should happen *after* the project phase, so we assume
that once they are implemented, `project` will still emit constructs
like lambdas and ADTs as opaque, primitive constructs.

## Design Considerations For Low-Level IR

This section details design considerations for the low-level IR & memory
model.

### Target Independence

Since the goal is to be able to translate the IR to multiple targets,
this IR must not be too closely tied to any one target.

### Amenable To Generating Efficient Code

The low level IR must facilitate generating efficient code for each
target platform.

### No Implicit Persistent State

All state that persists across transactions must be explicit. In
particular, we cannot rely on an implicit call and/or operand stack
across transactions; execution state must be stored explicitly.

### Consistent Data Layout

The IR emitted by the `project` phase has a data representation that is
consistent across participants and the consensus on the EVM. This
property will have to be maintained by the new low level IR & memory
model, for two reasons:

- To support UTXO chains, where the new state inherently must be
  computed off-chain.
- To allow us to continue to use an important optimization (detailed
  below) on the EVM, and anywhere else with similar cost considerations.

Note that it is possibly acceptable for the layout to be parametrized
over some target-platform specific details, such as endianness, word
size, etc, but the participants must agree with each other and with the
consensus on all of these.

#### Merklization Optimization

For background, one of the most expensive operations on EVM is the
SSTORE instruction, which writes data to persistent storage; most other
operations executed on the blockchain are orders of magnitude cheaper in
terms of gas.

To avoid having to pay to store the entire persistent state
of the consensus after each transaction, we instead compute a
cryptographic hash of the state, and store only that. When invoking
the contract, the participants must supply the complete persistent
state in the submitted transaction. The consensus checks this state
against its stored hash at the beginning of the transaction. In this
way, we only pay for one SSTORE instruction per transaction.

We call this the merklization optimization.

#### Interaction Multiplexing

MuKn has plans to multiplex difference instances of the same interaction
onto a single running Ethereum contract, and charge users a fee to use
the multiplexed contract, rather than pay the (high) gas costs to create
their own (see glow issue #157). The new low level IR must be able to
facilitate this. This will require being able to maintain both
interaction-local and contract-global state.

## Design considerations targeting Plutus Core

### Amenable To Generating Efficient Code

We would like Glow-on-Plutus to be reasonably efficient.

### Avoid Too Much Plutus-Specific Logic

We would like to avoid maintaining excessive amounts of Plutus-Specific
code in the Glow compiler.

### Use High-Level Facilities Of Plutus Core

As Glow adds high-level language features such closures, algebraic data
types, records, etc, low level backends will require additional runtime
support, for example for heap allocation and garbage collection.
However, Plutus Core supports some of these constructs (e.g. closures)
natively, and others can be encoded on top of Plutus' core features
(such as scott encoding ADTs). We should avoid imposing the low-level
constraints of other targets onto code targeting Plutus.

### State Comparison/Checking

On the current EVM target, we maintain state between transactions by
saving the program counter in memory, and hashing the raw bytes of
memory.  For other low level targets we can use a similar strategy.
However, Plutus is a lambda-calculus, and does not have a well defined
memory representation, so an alternative will have to be found.

In one way or another, we need to be able to store the contract state
between transactions in such a way that future transactions can restore
and verify it.

With Plutus as currently specified, this appears to be the most
difficult challenge in porting Glow to Plutus. Plutus currently provides
no facilities for serializing arbitrary terms, so any strategy here that
does not involve extensions to the platform is likely to incur
significant overheads, though we can do our best to minimise them.
Unfortunately, I(@isd) am not aware of a precise, documented cost model
for Plutus Core at present, so it is difficult to reason about this in
detail.

# Proposal

We define two additional IRs, and suggest extensions to untyped Plutus
Core for our use. We also explore alternative implementation options
in the event that IOG does not want to implement proposed extensions.

# Lambda Calculus

This section describes the higher-level IR, based on the lambda
calculus. This form has two purposes:

1. An intermediate stage in translation towards lower level targets.
2. A stage before targeting Plutus Core (which will not use the lower
   level IR at all).

## Overview

The high-level IR is recognizably lambda calculus. Noteworthy properties
include:

- Everything is still in ANF
- Lambdas have explicit capture lists (this will help when translating
  to low level IRs, and may help optimize serialization on plutus; see
  detailed discussion below).
- All side effects happen in an explicit effect monad, chained together
  with a monadic bind operator.
- Most high level constructs in Glow with simple operational semantics
  still exist as primitives at this level (e.g. ADTs/match, tuples,
  if/else, etc).
- The IR is not type checked. Down the line, we will likely introduce a
  typed variant, but we leave this for future work.

### Rationale For High Level Design Decisions

This section provides a brief rational for some of the high-level design
decisions described above.

#### Explicit Capture Lists

Lambdas in this IR have explicit capture lists. i.e. instead of:

```scheme
(lambda
    (x) ; parameters

    y ; body
)
```

You would have

```scheme
(lambda
    (y) ; list of varibles to capture; should include all
        ; free variables in the body.

    (x) ; parameters.

    y ; body
)
```

This is desirable for two reasons:

- When emitting low-level IR, we will have to explicitly construct
  closures in memory. This tells us what values to pack into the
  allocated closure.
- If we end up needing to do our own serialization for Plutus terms,
  this will allow us to easily identify what needs to be included in
  in a continuation.

#### Effect Monad

Side-effecting operations happen inside an explicit effect monad; we
would have this as part of our IR's AST:

```
Effect ::=
    ;; Standard monad things:
    | (eff-pure x) ; Return x without doing anything.
    | (eff-bind x f) ; Run x, then pass its result to f
    ;; A Glow-effect specific operation:
    | (eff-op EffOp)

EffOp ::=
    | (set-participant A) ; set the current participant to A
    | (require! x) ; assert that x is true
    | (deposit! x) ; current participant should deposit funds x
    | (withdraw! A x) ; A should withdraw funds x
    ;; ...
```

This approach has the following advantages:

- The continuation-passing nature of monads means that any operation
  that could commit the current transaction will not rely on the state
  of the call stack, which is critical since the call stack cannot be
  saved across transactions.
- It allows greater optimization, since we can readily identify pure
  terms.
- It is clear how this could translate to Plutus, since Plutus is itself
  a purely-functional lambda calculus. Likely on Plutus this will be
  some combination of State + Reader monad, with support for serializing
  its continuation should the transaction need to be committed.

A possible refinement of this is to actually have two separate effect
monads:

- One which contains operations that can commit the current transaction
  (e.g. set-participant)
- One that only contains operations that do *not* commit the current
  transaction (but may abort it).
- An operator to lift the latter into the former.

This would allow somewhat greater optimization; the call stack could
still be used for the latter monad. A first iteration of the
implementation should use the one-monad solution for simplicity though.

#### High Level Primitives

We keep things like ADTs, match, tuples etc. abstract at this stage,
since their representations between Plutus and lower level IRs are
likely to be unrelated. e.g. ADTs will be scott-encoded on Plutus,
but will likely use a tag word on low level targets instead.


#### Untyped

This IR is untyped for now, mainly for simplicity. In the future, we
may replace this with or add a typed IR based on F-sub (System F with
subtyping), which will make program transformations less error prone
and open up some new possibilities like evidence translation.

### AST Sketch

This section contains a rough sketch of the AST corresponding to this
IR.

```
;; expressions
Exp ::=
    ;; Let bindings. Since this IR is in ANF, a typical program will
    ;; contain *many* of these:
    (let Var Exp Exp)

    ;; standard lambda calculus stuff:
    (lambda (Var ...) (Var ...) Exp) ; lambdas, with capture lists
    Var ;; variables
    (apply Var (Var ...)) ; function application.

    ;; Monadic operations.
    (eff-bind Var Var)
    (eff-pure Var)
    (eff-op EffOp)

    Constant
    Builtin

Constant ::=
    (bool Boolean)
    (integer IntType Integer)
    ; maybe others

Builtin
    add ; integer addition
    sub ; subtraction
    ...
    or ; boolean or
    and
    ...

IntType ::=
    (int-type (signed? : Boolean) (num-bits : Integer))

EffOp ::=
    (get-participant)
    (set-participant! Var)
    (deposit! Var)
    (withdraw! Var Var) ; participant, funds
    (require! Var) ; Abort if Var is #f.
    ... ; other glow operators.
```

# Plutus Target

Cardano is a UTXO blockchain, where the on-chain script is a validator;
the transaction includes the output state, and the script merely
verifies that the output state is valid.

The Glow compiler will have to derive a validation script from the
source-level program, which computes the new state.

The most straightforward way of doing this is to generate a program
that computes the new state and then verifies that it matches what's
in the transaction (though in the future we can also support state
channels etc).

There is however one major challenge to doing this: the output state
must be in a form that can be compared. Plutus Core does not currently
provide a way for the on-chain script to compare arbitrary terms, or
to (de)serialize them.

We propose extending Untyped Plutus Core with operations for serializing
and deserializing arbitrary terms. This massively simplifies the job
of the glow compiler, which can then, on transaction commit, simply
serialize the continuation passed to `eff-bind`, and compare it to what
is in the transaction's outputs.

If we are unable to get such operations added, we could in the worst case
write an interpreter for our IR that runs on plutus, allowing us to
inspect the (interpreted) terms. This would introduce overheads, but
that is likely the case with any scheme we use to serialize
continuations, since we must not encode them as lambdas. We may be
able to optimize this such that some code can be compiled more directly
to plutus core (and treated as a builtin by our interpreter), if it
can be shown that doing so does not introduce persistent state
that cannot be serialized.

# Low Level IR

This section describes the low level IR and memory model.

## Memory Model Overview

The memory model has some commonalities with executable formats such as
ELF. In particular, the format divides memory for statically allocated
variables into *sections*, based on the properties of variables:

- Does it persist across transactions?
- Is it interaction local, or is it going to be global once interaction
  multiplexing is implemented? (See #157 and related issues).
- Is the caller able to specify their own value for this, or is this
  protected by the consensus? Useful for passing in parameters.
- Is it merklization-safe?

Each section has an offset, and each variable has an offset within its
section. We sort the sections into memory regions as follows:

- Ephemeral (transaction-local) sections come first.
- Then come persistent, merklization-safe interaction-global (i.e. not
  interaction-local) variables.
- Then come persistent, merklization-safe interaction-*local* variables.
- Then come parameter sections.

Operations are limited to a fixed set of low-level types. We may be
able to get away with just integers of various fixed widths, but we
may also want to include:

- booleans
- (data)addresses
- function-labels

Code is grouped into functions, which have parameters, return values,
and a body:

    function-def =
        (function-name (params...) function-body)

    function-body =
        ; one or more blocks:
        (block...)

    block =
        (block label
            stmts...
            branch)

    branch =
        (return expr)
        (jump label)
        (tail-call function expr...)
        (switch expr ((value label) (value label)...) default-label?)


A statement is one of:

    (mstore variable expr)
    (ignore expr) ; evaluate an expression for its side effect,
                  ; ignoring any result.
    ...

We actually allow nested expressions at this level, again, relaxing the
ANF transformation we did earlier in the compiler. The reason for this
is that it makes it easy to generate code for the lower level layers:
Just do post-order tree traversal. If the target is a stack machine
(like EVM), we just push arguments, if it's SSA (like LLVM) we give each
subtree a name and do an assignment. This allows us to avoid superfluous
intermediate variables, which is important since at this stage we
allocate memory space for all variables -- so we can't optimize them out
later, it has to be now.

Memory *loads* can be expressions, but not memory *stores*, which are
statements.

Expressions are one of:

    (mload variable)
    (call function expr...)
    (builtin op expr...) ; misc built-in operators.
    ...

TODO: heap, dynamic segments.