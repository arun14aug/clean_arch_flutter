// Mocks generated by Mockito 5.4.4 from annotations
// in clean_arch/test/core/domain/usecases/add_note_usescase_test.dart.
// Do not manually edit this file.

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'dart:async' as _i4;

import 'package:clean_arch/core/data/dto/note_model.dart' as _i5;
import 'package:clean_arch/core/data/dto/note_request_model.dart' as _i6;
import 'package:clean_arch/core/domain/repositories/note_repository_contract.dart'
    as _i3;
import 'package:clean_arch/network/entities/base_response.dart' as _i2;
import 'package:mockito/mockito.dart' as _i1;

// ignore_for_file: type=lint
// ignore_for_file: avoid_redundant_argument_values
// ignore_for_file: avoid_setters_without_getters
// ignore_for_file: comment_references
// ignore_for_file: deprecated_member_use
// ignore_for_file: deprecated_member_use_from_same_package
// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member
// ignore_for_file: prefer_const_constructors
// ignore_for_file: unnecessary_parenthesis
// ignore_for_file: camel_case_types
// ignore_for_file: subtype_of_sealed_class

class _FakeBaseResponse_0<T> extends _i1.SmartFake
    implements _i2.BaseResponse<T> {
  _FakeBaseResponse_0(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

/// A class which mocks [NoteRepositoryContract].
///
/// See the documentation for Mockito's code generation for more information.
class MockNoteRepositoryContract extends _i1.Mock
    implements _i3.NoteRepositoryContract {
  MockNoteRepositoryContract() {
    _i1.throwOnMissingStub(this);
  }

  @override
  _i4.Future<_i2.BaseResponse<dynamic>> getNotes() => (super.noSuchMethod(
        Invocation.method(
          #getNotes,
          [],
        ),
        returnValue: _i4.Future<_i2.BaseResponse<dynamic>>.value(
            _FakeBaseResponse_0<dynamic>(
          this,
          Invocation.method(
            #getNotes,
            [],
          ),
        )),
      ) as _i4.Future<_i2.BaseResponse<dynamic>>);

  @override
  _i4.Future<_i2.BaseResponse<dynamic>> addNote(_i5.NoteModel? noteModel) =>
      (super.noSuchMethod(
        Invocation.method(
          #addNote,
          [noteModel],
        ),
        returnValue: _i4.Future<_i2.BaseResponse<dynamic>>.value(
            _FakeBaseResponse_0<dynamic>(
          this,
          Invocation.method(
            #addNote,
            [noteModel],
          ),
        )),
      ) as _i4.Future<_i2.BaseResponse<dynamic>>);

  @override
  _i4.Future<_i2.BaseResponse<dynamic>> deleteNote(
          _i6.NoteRequestModel? noteRequestModel) =>
      (super.noSuchMethod(
        Invocation.method(
          #deleteNote,
          [noteRequestModel],
        ),
        returnValue: _i4.Future<_i2.BaseResponse<dynamic>>.value(
            _FakeBaseResponse_0<dynamic>(
          this,
          Invocation.method(
            #deleteNote,
            [noteRequestModel],
          ),
        )),
      ) as _i4.Future<_i2.BaseResponse<dynamic>>);

  @override
  _i4.Future<_i2.BaseResponse<dynamic>> updateNote(
          _i6.NoteRequestModel? noteRequestModel) =>
      (super.noSuchMethod(
        Invocation.method(
          #updateNote,
          [noteRequestModel],
        ),
        returnValue: _i4.Future<_i2.BaseResponse<dynamic>>.value(
            _FakeBaseResponse_0<dynamic>(
          this,
          Invocation.method(
            #updateNote,
            [noteRequestModel],
          ),
        )),
      ) as _i4.Future<_i2.BaseResponse<dynamic>>);
}
