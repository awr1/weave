# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import locks, atomics, typetraits

const CacheLineSize {.intdefine.} = 64
  ## True on most machines
  ## Notably false on Samsung phones
  ## We might need to use 2x CacheLine to avoid prefetching cache conflict

type
  ChannelShmMpscBoundedLock*[T] = object
    ## Lock-based multi-producer single-consumer channel
    ##
    ## Properties:
    ##   - Lock-based for the producers
    ##   - lock-free for the consumer
    ##   - no modulo operations
    ##   - memory-efficient: buffer the size of the capacity
    ##   - Padded to avoid false sharing
    ##   - No extra indirection to access the item
    ##   - Linearizable
    ##
    ## Usage:
    ##   When producer wait/sleep is not an issue as they don't have
    ##   useful work to do.
    ##
    ## At the moment, only trivial objects can be received or sent
    ## (no GC, can be copied and no custom destructor)
    ##
    ## The content of the channel is not destroyed upon channel destruction
    ## Destroying a channel containing ptr object will not deallocate them
    backLock: Lock # Padding? - pthread_lock is 40 bytes on Linux, unknown on windows.
    capacity: int
    buffer: ptr UncheckedArray[T]
    pad1: array[CacheLineSize - sizeof(int), byte]
    front: Atomic[int]
    pad2: array[CacheLineSize - sizeof(int), byte]
    back: Atomic[int]

  # Private aliases
  Channel[T] = ChannelShmMpscBoundedLock[T]

proc `=`[T](
    dest: var Channel[T],
    source: Channel[T]
  ) {.error: "A channel cannot be copied".}

proc `=destroy`[T](chan: var Channel[T]) {.inline.} =
  static: assert T.supportsCopyMem # no custom destructors or ref objects
  if not chan.buffer.isNil:
    dealloc(chan.buffer)

func clear*(chan: var Channel) {.inline.} =
  ## Reinitialize the data in the channel
  ## We assume the buffer was already initialized.
  ##
  ## This is not threadsafe
  assert not chan.buffer.isNil
  chan.front.store(0, moRelaxed)
  chan.back.store(0, moRelaxed)

proc initialize*[T](chan: var Channel[T], capacity: Positive) =
  ## Creates a new Shared Memory Multi-Producer Producer Single Consumer Bounded channel

  # No init, we don't need to zero-mem the padding
  # `createU` is thread-local allocation.
  # No risk of false-sharing

  static: assert T.supportsCopyMem
  assert cast[ByteAddress](chan.back.addr) -
    cast[ByteAddress](chan.front.addr) >= CacheLineSize

  chan.capacity = capacity
  chan.buffer = cast[ptr UncheckedArray[T]](createU(T, capacity))
  chan.clear()

# To differentiate between full and empty case
# we don't rollover the front and back indices to 0
# when they reach capacity.
# But only when they reach 2*capacity.
# When they are the same the queue is empty.
# When the difference is capacity, the queue is full.

func isFull(chan: var Channel, back: var int): bool {.inline.} =
  ## Check if channel is full
  ## Update the back index value with its atomically read value
  ##
  ## ⚠ Use only in:
  ##   - a producer thread that writes to the "back" index
  ##     (send / enqueue / pushBack)
  back = chan.back.load(moRelaxed)
  let num_items = back - chan.front.load(moAcquire)
  result = abs(num_items) == chan.capacity

template isFull(chan: var Channel): bool =
  ## Check if channel is full
  ## ⚠ Use only in:
  ##   - a producer thread that writes to the "back" index
  ##     (send / enqueue / pushBack)
  var back: int
  chan.isFull(back)

func trySend*[T](chan: var Channel[T], src: sink T): bool =
  ## Try sending in the back slot of the channel
  ## Returns true if successful
  ## Returns false if the channel was full
  ##
  ## ⚠ Use only in the producer threads that write into the channel.
  ## ⚠ This is a blocking operation, in case 2 producers try to send a message
  ##    one will be put to sleep.
  if chan.isFull():
    return false

  acquire(chan.backLock)
  var back: int

  # Check again if full, if not cache the atomically read back index
  # - front: moAcquire
  # - back: moRelaxed
  if chan.isFull(back):
    # Another thread was faster
    release(chan.backLock)
    return false

  `=sink`(chan.buffer[back], src)

  var nextWrite = back + 1
  if nextWrite == 2 * chan.capacity:
    nextWrite = 0
  chan.back.store(nextWrite, moRelease)

  release(chan.backLock)
  return true

func tryRecv*[T](chan: var Channel[T], dst: var T): bool =
  ## Try receiving the next item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ##
  ## ⚠ Use only in the consumer thread that reads from the channel.
  let front = chan.front.load(moRelaxed)
  if front == chan.back.load(moAcquire):
    # Empty
    return false

  dst = move chan.buffer[front]

  var nextRead = front + 1
  if nextRead == 2 * chan.capacity:
    nextRead = 0
  chan.front.store(nextRead, moRelease)
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
      doAssert args.chan[].isFull() == false
      for j in 0 ..< 10:
        let val = 42 + j*11
        args.chan[].sendLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "Sender sent: ", val

  proc main(capacity: int) =
    echo "Testing if 2 threads can send data - channel capacity: ", capacity
    echo "-----------------------------------"
    var threads: array[2, Thread[ThreadArgs]]
    let chan = createU(Channel[int]) # CreateU is not zero-init
    chan[].initialize(capacity)

    createThread(threads[0], thread_func, ThreadArgs(ID: Receiver, chan: chan))
    createThread(threads[1], thread_func, ThreadArgs(ID: Sender, chan: chan))

    joinThread(threads[0])
    joinThread(threads[1])

    dealloc(chan)
    echo "-----------------------------------"
    echo "Success"

  main(2)
  main(10)