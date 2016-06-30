// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

part of core;

/// The object passed to the handler's error handling function containing both
/// the thrown error and the associated stack trace.
class MojoEventHandlerError {
  final Object error;
  final StackTrace stacktrace;

  MojoEventHandlerError(this.error, this.stacktrace);

  @override
  String toString() => error.toString();
}

typedef void ErrorHandler(MojoEventHandlerError e);

class MojoEventHandler {
  MojoMessagePipeEndpoint _endpoint;
  MojoEventSubscription _eventSubscription;
  bool _isOpen = false;
  bool _isInHandler = false;
  bool _isPeerClosed = false;

  MojoEventHandler.fromEndpoint(MojoMessagePipeEndpoint endpoint,
                                {bool autoBegin: true})
      : _endpoint = endpoint,
        _eventSubscription = new MojoEventSubscription(endpoint.handle) {
    if (autoBegin) {
      beginHandlingEvents();
    }
  }

  MojoEventHandler.fromHandle(MojoHandle handle, {bool autoBegin: true})
      : _endpoint = new MojoMessagePipeEndpoint(handle),
        _eventSubscription = new MojoEventSubscription(handle) {
    if (autoBegin) {
      beginHandlingEvents();
    }
  }

  MojoEventHandler.unbound();

  /// The event handler calls the [handleRead] method when the underlying Mojo
  /// message pipe endpoint has a message available to be read. Implementers
  /// should read, decode, and handle the message. If [handleRead] throws
  /// an exception derived from [Error], the exception will be thrown into the
  /// root zone, and the application will end. Otherwise, the exception object
  /// will be passed to [onError] if it has been set, and the exception will
  /// not be propagated to the root zone.
  void handleRead() {}

  /// Like [handleRead] but indicating that the underlying message pipe endpoint
  /// is ready for writing.
  void handleWrite() {}

  /// Called when [handleRead] or [handleWrite] throw an exception generated by
  /// Mojo library code. Other exceptions will be re-thrown.
  ErrorHandler onError;

  MojoMessagePipeEndpoint get endpoint => _endpoint;
  bool get isOpen => _isOpen;
  bool get isInHandler => _isInHandler;
  bool get isBound => _endpoint != null;
  bool get isPeerClosed => _isPeerClosed;

  void bind(MojoMessagePipeEndpoint endpoint) {
    if (isBound) {
      throw new MojoApiError("MojoEventHandler is already bound.");
    }
    _endpoint = endpoint;
    _eventSubscription = new MojoEventSubscription(endpoint.handle);
    _isOpen = false;
    _isInHandler = false;
    _isPeerClosed = false;
  }

  void bindFromHandle(MojoHandle handle) {
    if (isBound) {
      throw new MojoApiError("MojoEventHandler is already bound.");
    }
    _endpoint = new MojoMessagePipeEndpoint(handle);
    _eventSubscription = new MojoEventSubscription(handle);
    _isOpen = false;
    _isInHandler = false;
    _isPeerClosed = false;
  }

  void beginHandlingEvents() {
    if (!isBound) {
      throw new MojoApiError("MojoEventHandler is unbound.");
    }
    if (_isOpen) {
      throw new MojoApiError("MojoEventHandler is already handling events");
    }
    _isOpen = true;
    _eventSubscription.subscribe(_tryHandleEvent);
  }

  /// [endHandlineEvents] unsubscribes from the underlying
  /// [MojoEventSubscription].
  void endHandlingEvents() {
    if (!isBound || !_isOpen || _isInHandler) {
      throw new MojoApiError(
          "MojoEventHandler was not handling events when instructed to end");
    }
    if (_isInHandler) {
      throw new MojoApiError(
          "Cannot end handling events from inside a callback");
    }
    _isOpen = false;
    _eventSubscription.unsubscribe();
  }

  /// [unbind] stops handling events, and returns the underlying
  /// [MojoMessagePipe]. The pipe can then be rebound to the same or different
  /// [MojoEventHandler], or closed. [unbind] cannot be called from within
  /// [handleRead] or [handleWrite].
  MojoMessagePipeEndpoint unbind() {
    if (!isBound) {
      throw new MojoApiError(
          "MojoEventHandler was not bound in call in unbind()");
    }
    if (_isOpen) {
      endHandlingEvents();
    }
    if (_isInHandler) {
      throw new MojoApiError(
          "Cannot unbind a MojoEventHandler from inside a callback.");
    }
    var boundEndpoint = _endpoint;
    _endpoint = null;
    _eventSubscription = null;
    return boundEndpoint;
  }

  Future close({bool immediate: false}) {
    var result;
    _isOpen = false;
    _endpoint = null;
    if (_eventSubscription != null) {
      result = _eventSubscription
          ._close(immediate: immediate, local: _isPeerClosed)
          .then((_) {
        _eventSubscription = null;
      });
    }
    return result != null ? result : new Future.value(null);
  }

  @override
  String toString() => "MojoEventHandler("
      "isOpen: $_isOpen, isBound: $isBound, endpoint: $_endpoint)";

  void _tryHandleEvent(int event) {
    // This callback is running in the handler for a RawReceivePort. All
    // exceptions rethrown or not caught here will be unhandled exceptions in
    // the root zone, bringing down the whole app. An app should rather have an
    // opportunity to handle exceptions coming from Mojo, like the
    // MojoCodecError.
    // TODO(zra): Rather than hard-coding a list of exceptions that bypass the
    // onError callback and are rethrown, investigate allowing an implementer to
    // provide a filter function (possibly initialized with a sensible default).
    try {
      _handleEvent(event);
    } on Error catch (_) {
      // An Error exception from the core libraries is probably a programming
      // error that can't be handled. We rethrow the error so that
      // MojoEventHandlers can't swallow it by mistake.
      rethrow;
    } catch (e, s) {
      close(immediate: true).then((_) {
        if (onError != null) {
          onError(new MojoEventHandlerError(e, s));
        }
      });
    }
  }

  void _handleEvent(int signalsReceived) {
    if (!_isOpen) {
      // The actual close of the underlying stream happens asynchronously
      // after the call to close. However, we start to ignore incoming events
      // immediately.
      return;
    }
    _isInHandler = true;
    if (MojoHandleSignals.isReadable(signalsReceived)) {
      handleRead();
    }
    if (MojoHandleSignals.isWritable(signalsReceived)) {
      handleWrite();
    }
    _isPeerClosed = MojoHandleSignals.isPeerClosed(signalsReceived) ||
        !_eventSubscription.enableSignals();
    _isInHandler = false;
    if (_isPeerClosed) {
      close().then((_) {
        if (onError != null) {
          onError(null);
        }
      });
    }
  }
}