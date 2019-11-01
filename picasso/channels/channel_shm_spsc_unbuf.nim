# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/atomics, std/typetraits

const CacheLineSize {.intdefine.} = 64
  ## True on most machines
  ## Notably false on Samsung phones
  ## We might need to use 2x CacheLine to avoid prefetching cache conflict

type
  ChannelShmSpscSingle*[T] = object
    ## Wait-free bounded single-producer single-consumer channel
    ## That can only buffer a single item (a Picasso task)
    ## Properties:
    ##   - wait-free
    ##   - supports weak memory models
    ##   - no modulo operations
    ##   - memory-efficient: buffer the size of the capacity
    ##   - Padded to avoid false sharing
    ##   - only 1 synchronization variable.
    ##   - No extra indirection to access the item
    ##
    ## Requires T to fit in a CacheLine
    pad0: array[CacheLineSize, byte] # If used in a sequence of channels
    buffer: T
    pad1: array[CacheLineSize  - sizeof(T), byte]
    full: Atomic[bool]

  # Private aliases
  Channel[T] = ChannelShmSpscSingle[T]

proc `=`[T](
    dest: var Channel[T],
    source: Channel[T]
  ) {.error: "A channel cannot be copied".}

func clear*(chan: var Channel) {.inline.} =
  ## Reinitialize the data in the channel
  ## This is not thread-safe.
  assert chan.full.load(moRelaxed) == true
  `=destroy`(chan.buffer)
  chan.full.store(moRelaxed) = false

func tryRecv*[T](chan: var Channel[T], dst: var T): bool =
  ## Try receiving the item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ##
  ## ⚠ Use only in the consumer thread that reads from the channel.
  let full = chan.full.load(moAcquire)
  if not full:
    return false
  dst = move chan.buffer
  chan.full.store(false, moRelease)
  return true

func trySend*[T](chan: var Channel[T], src: sink T): bool =
  ## Try sending an item into the channel
  ## Reurns true if successful (channel was empty)
  ##
  ## ⚠ Use only in the producer thread that writes from the channel.
  let full = chan.full.load(moAcquire)
  if full:
    return false
  `=sink`(chan.buffer, src)
  chan.full.store(true, moRelease)
  return true

# Sanity checks
# ------------------------------------------------------------------------------
when isMainModule:
  when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

  template sendLoop[T](chan: var Channel[T],
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T](chan: var Channel[T],
                       data: var T,
                       body: untyped): untyped =
    while not chan.tryRecv(data):
      body

  type
    ThreadArgs = object
      ID: WorkerKind
      chan: ptr Channel[int]

    WorkerKind = enum
      Sender
      Receiver

  template Worker(id: WorkerKind, body: untyped): untyped {.dirty.} =
    if args.ID == id:
      body

  proc thread_func(args: ThreadArgs) =

    # Worker RECEIVER:
    # ---------
    # <- chan
    # <- chan
    # <- chan
    #
    # Worker SENDER:
    # ---------
    # chan <- 42
    # chan <- 53
    # chan <- 64
    Worker(Receiver):
      var val: int
      for j in 0 ..< 10:
        args.chan[].recvLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "                  Receiver got: ", val
        doAssert val == 42 + j*11

    Worker(Sender):
      doAssert args.chan.full.load(moRelaxed) == false
      for j in 0 ..< 10:
        let val = 42 + j*11
        args.chan[].sendLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "Sender sent: ", val

  proc main() =
    echo "Testing if 2 threads can send data"
    echo "-----------------------------------"
    var threads: array[2, Thread[ThreadArgs]]
    let chan = create(Channel[int]) # Create is zero-init

    createThread(threads[0], thread_func, ThreadArgs(ID: Receiver, chan: chan))
    createThread(threads[1], thread_func, ThreadArgs(ID: Sender, chan: chan))

    joinThread(threads[0])
    joinThread(threads[1])

    dealloc(chan)
    echo "-----------------------------------"
    echo "Success"

  main()
