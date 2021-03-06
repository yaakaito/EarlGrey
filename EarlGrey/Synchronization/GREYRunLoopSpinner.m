//
// Copyright 2016 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "Synchronization/GREYRunLoopSpinner.h"

#import "Additions/UIApplication+GREYAdditions.h"
#import "Assertion/GREYAssertionDefines.h"

/**
 *  The default minimum number of run loop drains. The default is 2 because, as per the CFRunLoop
 *  implementation, some ports (specifically the dispatch port) will only be serviced every other
 *  run loop drain.
 */
static const int kDefaultMinRunLoopDrains = 2;

/**
 *  No-op timer handler block.
 */
static void (^noopTimerHandler)(CFRunLoopTimerRef timer) = ^(CFRunLoopTimerRef timer){};

@implementation GREYRunLoopSpinner {
  BOOL _spinning;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _minRunLoopDrains = kDefaultMinRunLoopDrains;
  }
  return self;
}

- (BOOL)spinWithStopConditionBlock:(BOOL (^)(void))stopConditionBlock {
  I_CHECK_MAIN_THREAD();
  NSAssert(!_spinning, @"Should not spin the same run loop spinner instance concurrently.");
  
  _spinning = YES;
  CFTimeInterval timeoutTime = CACurrentMediaTime() + self.timeout;

  [self grey_drainRunLoopInActiveModeForDrains:self.minRunLoopDrains];

  BOOL stopConditionMet = [self grey_checkConditionInActiveMode:stopConditionBlock];
  CFTimeInterval remainingTime = [self grey_secondsUntilTime:timeoutTime];

  while (!stopConditionMet && remainingTime > 0) {
    @autoreleasepool {
      stopConditionMet = [self grey_drainRunLoopInActiveModeAndCheckCondition:stopConditionBlock
                                                                      forTime:remainingTime];
      remainingTime = [self grey_secondsUntilTime:timeoutTime];
    }
  }

  _spinning = NO;
  return stopConditionMet;
}

#pragma mark - Private Methods

/**
 *  Spins the run loop in the active mode for @c exitDrainCount drains.
 *
 *  @param exitDrainCount The number of times to drain the active run loop.
 */
- (void)grey_drainRunLoopInActiveModeForDrains:(int)exitDrainCount {
  __block int drainCount = 0;

  void (^drainCountingBlock)() = ^{
    drainCount++;
    if (drainCount >= exitDrainCount) {
      CFRunLoopStop(CFRunLoopGetMain());
    }
  };

  void (^wakeUpBlock)() = ^{
    // Never let the run loop sleep while we are draining it for the minimum drains.
    CFRunLoopWakeUp(CFRunLoopGetMain());
  };

  // Drain the currently active mode in a while loop so that we handle cases where the active mode
  // finishes or is stopped. In these cases, we want to keep draining the (possibly new) active mode
  // for the remaining drains.
  while (drainCount < exitDrainCount) {
    @autoreleasepool {
      CFStringRef activeMode = CFBridgingRetain([self grey_activeRunLoopMode]);
      CFRunLoopObserverRef drainCountingObserver = [self grey_setupObserverInMode:activeMode
                                                           withBeforeSourcesBlock:drainCountingBlock
                                                               beforeWaitingBlock:wakeUpBlock];

      CFRunLoopRunResult result = CFRunLoopRunInMode(activeMode, DBL_MAX, false);
      if (result == kCFRunLoopRunFinished) {
        // Running a run loop mode will finish if that mode has no sources or timers. In that case,
        // the observer callbacks will not get called, so we need to increment the drain count here.
        drainCount++;
      }
      [self grey_teardownObserver:drainCountingObserver inMode:activeMode];
      CFRelease(activeMode);
    }
  }
}

/**
 *  Spins the run loop in the active mode until the stop condition has been met, we have timed
 *  out, the run loop finishes, or the run loop is stopped by someone else. Checks the stop
 *  condition at least once per run loop drain.
 *
 *  @param stopConditionBlock The condition block that should be checked to determine if we should
 *                            stop initiating drains in the active mode.
 *  @param time               The timeout time after which we should stop initiate drains.
 *
 *  @return @c YES if the condition block was evaluated to YES while draining or after the active
 *          run loop finished; @c NO otherwise.
 */
- (BOOL)grey_drainRunLoopInActiveModeAndCheckCondition:(BOOL (^)())stopConditionBlock
                                               forTime:(CFTimeInterval)time {
  CFStringRef activeMode = CFBridgingRetain([self grey_activeRunLoopMode]);
  CFRunLoopTimerRef wakeUpTimer = [self grey_setupWakeUpTimerInMode:activeMode];
  __block BOOL conditionMet = NO;
  __weak __typeof__(self) weakSelf = self;

  void (^beforeSourcesConditionCheckBlock)() = ^{
    __typeof__(self) strongSelf = weakSelf;
    NSAssert(strongSelf, @"The spinner should not have been deallocated while it was spinning.");

    if (stopConditionBlock()) {
      if ([strongSelf conditionMetHandler]) {
        [strongSelf conditionMetHandler]();
      }
      conditionMet = YES;
      CFRunLoopStop(CFRunLoopGetMain());
    }
  };

  void (^beforeWaitingConditionCheckBlock)() = ^{
    __typeof__(self) strongSelf = weakSelf;
    NSAssert(strongSelf, @"The spinner should not have been deallocated while it was spinning.");

    if ([strongSelf maxSleepInterval] == 0) {
      CFRunLoopWakeUp(CFRunLoopGetMain());
    }

    // This observer callback is not guaranteed to be called, but we must also check if we should
    // stop the run loop here because we do not want the run loop to go to sleep if we should stop
    // the run loop. A source handled in the last drain may have satisfied the stop condition.
    //
    // Do not check _stopConditionBlock if _stopConditionMet is already true. This will occur if we
    // stopped the run loop in the BeforeSources handler. In this case, we do not want to check the
    // stop condition again.
    if (!conditionMet && stopConditionBlock()) {
      if ([strongSelf conditionMetHandler]) {
        [strongSelf conditionMetHandler]();
      }
      conditionMet = YES;
      CFRunLoopStop(CFRunLoopGetMain());
    }
  };

  CFRunLoopObserverRef conditionCheckingObserver =
      [self grey_setupObserverInMode:activeMode
              withBeforeSourcesBlock:beforeSourcesConditionCheckBlock
                  beforeWaitingBlock:beforeWaitingConditionCheckBlock];

  CFRunLoopRunResult result = CFRunLoopRunInMode(activeMode, time, false);

  // Running a run loop mode will finish if that mode has no sources or timers. In that case,
  // the observer callbacks will not get called, so we need to check the condition here.
  if (result == kCFRunLoopRunFinished) {
    NSAssert(!conditionMet, @"If the running the active mode returned finished, the condition"
                            @"should not have been met.");
    conditionMet = [self grey_checkConditionInActiveMode:stopConditionBlock];
  }

  [self grey_teardownObserver:conditionCheckingObserver inMode:activeMode];
  [self grey_teardownTimer:wakeUpTimer inMode:activeMode];
  CFRelease(activeMode);

  return conditionMet;
}

/**
 *  Checks the stop condition block in the active mode and invokes the condition met handler in the
 *  active mode if it was evaluated to @c YES.
 *
 *  @param stopConditionBlock The condition block that should be evaluated in the active mode.
 *
 *  @return @c YES if the stop condition block evaluated to @YES; @c NO otherwise.
 */
- (BOOL)grey_checkConditionInActiveMode:(BOOL (^)())stopConditionBlock  {
  __block BOOL conditionMet = NO;
  __weak __typeof__(self) weakSelf = self;

  CFStringRef activeMode = CFBridgingRetain([self grey_activeRunLoopMode]);
  CFRunLoopPerformBlock(CFRunLoopGetMain(), activeMode, ^{
    __typeof__(self) strongSelf = weakSelf;
    NSAssert(strongSelf, @"The spinner should not have been deallocated while it was spinning.");

    if (stopConditionBlock()) {
      void (^conditionMetHandler)(void) = [strongSelf conditionMetHandler];
      if (conditionMetHandler) {
        conditionMetHandler();
      }
      conditionMet = YES;
    }
  });
  // Handles at most one souce in the active mode. All enqueued blocks are serviced before any
  // sources are serviced.
  CFRunLoopRunInMode(activeMode, 0, true);

  CFRelease(activeMode);
  return conditionMet;
}

/**
 *  Setup an observer in @c mode that will invoke the provided blocks when the on the appropriate
 *  observer events if and only if the run loop is running in @c mode and the mode has not been
 *  nested.
 *
 *  @remark We consider a mode "nested" if a source handled while we are spinning the run loop
 *          starts spinning the run loop in the same mode.
 *
 *  @param mode               The mode that the observer should be added to.
 *  @param beforeSourcesBlock Block that will be invoked when the added observer recieves before-
 *                            sources callbacks and is not nested.
 *  @param beforeWaitingBlock Block that will be invoked when the added observer recieves before-
 *                            waiting callbacks and is not nested.
 *
 *  @return The registered observer.
 */
- (CFRunLoopObserverRef)grey_setupObserverInMode:(CFStringRef)mode
                          withBeforeSourcesBlock:(void (^)())beforeSourcesBlock
                              beforeWaitingBlock:(void (^)())beforeWaitingBlock {
  __block int numNestedRunLoopModes = 0;

  void (^observerBlock)(CFRunLoopObserverRef observer, CFRunLoopActivity activity) =
      ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
        if (activity & kCFRunLoopEntry) {
          // When entering a run loop in @c mode, increment the nesting count.
          numNestedRunLoopModes++;
        } else if (activity & kCFRunLoopExit) {
          // When exiting a run loop in @c mode, decrement the nesting count.
          numNestedRunLoopModes--;
        } else if (activity & kCFRunLoopBeforeSources) {
          // When this observer was created, the nesting count was 0. When we started running the
          // run loop in @c mode, the run loop entered @c mode and incremented the nesting count. So
          // now, the "unnested" nesting count is 1.
          if (numNestedRunLoopModes == 1) {
            beforeSourcesBlock();
          }
        } else if (activity & kCFRunLoopBeforeWaiting) {
          if (numNestedRunLoopModes == 1) {
            beforeWaitingBlock();
          }
        } else {
          NSAssert(NO, @"Should not get here. Observer is not registered for any other options.");
        }
        NSAssert(numNestedRunLoopModes >= 0,
                 @"The nesting count for |mode| should never be less than zero.");
      };

  CFOptionFlags observerFlags = kCFRunLoopEntry | kCFRunLoopExit;
  if (beforeSourcesBlock) {
    observerFlags = observerFlags | kCFRunLoopBeforeSources;
  }
  if (beforeWaitingBlock) {
    observerFlags = observerFlags | kCFRunLoopBeforeWaiting;
  }

  // Order = LONG_MAX so it is serviced last after all other higher priority observers.
  // Let the other observers do their job before querying for idleness.
  CFRunLoopObserverRef observer =
      CFRunLoopObserverCreateWithHandler(NULL, observerFlags, true, LONG_MAX, observerBlock);
  CFRunLoopAddObserver(CFRunLoopGetMain(), observer, mode);
  return observer;
}

/**
 *  Create and return a wake up timer in @c mode. Will not add a timer if @c maxSleepInterval
 *  is 0. The wake up timer will fire every @c maxSleepInterval to keep the run loop from sleeping
 *  more than @c maxSleepInterval while running in @c mode.
 *
 *  @param mode The mode that the timer should be added to.
 *
 *  @return The registered timer or @c nil if no timer was added to @c mode.
 */
- (CFRunLoopTimerRef)grey_setupWakeUpTimerInMode:(CFStringRef)mode {
  if (self.maxSleepInterval > 0) {
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
                                                              CFAbsoluteTimeGetCurrent(),
                                                              self.maxSleepInterval,
                                                              0,
                                                              0,
                                                              noopTimerHandler);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, mode);
    return timer;
  } else {
    return NULL;
  }
}

/**
 *  Remove @c observer from @c mode and then release it.
 *
 *  @param observer The observer to be removed and released.
 *  @param mode     The mode from which the observer should be removed.
 */
- (void)grey_teardownObserver:(CFRunLoopObserverRef)observer inMode:(CFStringRef)mode {
  if (observer) {
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, mode);
    CFRelease(observer);
  }
}

/**
 *  Remove @c timer from @c mode and then release it.
 *
 *  @param timer The time to be removed and released.
 *  @param mode  The mode from which the timer should be removed.
 */
- (void)grey_teardownTimer:(CFRunLoopTimerRef)timer inMode:(CFStringRef)mode {
  if (timer) {
    CFRunLoopRemoveTimer(CFRunLoopGetMain(), timer, mode);
    CFRelease(timer);
  }
}

/**
 *  @param time The point in time to measure against.
 *
 *  @return The time in seconds from now until @c time.
 */
- (CFTimeInterval)grey_secondsUntilTime:(CFTimeInterval)time {
  return time - CACurrentMediaTime();
}

/**
 *  @return The active mode for the main runloop.
 */
- (NSString *)grey_activeRunLoopMode {
  NSString *activeRunLoopMode = [[UIApplication sharedApplication] grey_activeRunLoopMode];
  if (!activeRunLoopMode) {
    // If UIKit does not have any modes on its run loop stack, then consider the default
    // run loop mode as the active mode. We do not use the current run loop mode because if this
    // spinner is nested within another spinner, we could get stuck spinning the run loop in a
    // mode that was active but shouldn't be anymore.
    // TODO: Do better than just always using the default run loop mode.
    activeRunLoopMode = NSDefaultRunLoopMode;
  }
  return activeRunLoopMode;
}

# pragma mark - Getters and Setters

- (void)setMaxSleepInterval:(CFTimeInterval)maxSleepInterval {
  NSAssert(maxSleepInterval >= 0, @"Maximum sleep interval must be non-negative.");
  _maxSleepInterval = maxSleepInterval;
}

- (void)setTimeout:(CFTimeInterval)timeout {
  NSAssert(timeout >= 0, @"Timeout must be non-negative.");
  _timeout = timeout;
}

@end