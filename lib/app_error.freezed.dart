// dart format width=80
// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'app_error.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$EcashAppError {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EcashAppError()';
}


}

/// @nodoc
class $EcashAppErrorCopyWith<$Res>  {
$EcashAppErrorCopyWith(EcashAppError _, $Res Function(EcashAppError) __);
}


/// @nodoc


class EcashAppError_ExpiredInvoice extends EcashAppError {
  const EcashAppError_ExpiredInvoice(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_ExpiredInvoice);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EcashAppError.expiredInvoice()';
}


}




/// @nodoc


class EcashAppError_InsufficientBalance extends EcashAppError {
  const EcashAppError_InsufficientBalance({required this.neededMsats, required this.haveMsats}): super._();
  

 final  BigInt neededMsats;
 final  BigInt haveMsats;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EcashAppError_InsufficientBalanceCopyWith<EcashAppError_InsufficientBalance> get copyWith => _$EcashAppError_InsufficientBalanceCopyWithImpl<EcashAppError_InsufficientBalance>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_InsufficientBalance&&(identical(other.neededMsats, neededMsats) || other.neededMsats == neededMsats)&&(identical(other.haveMsats, haveMsats) || other.haveMsats == haveMsats));
}


@override
int get hashCode => Object.hash(runtimeType,neededMsats,haveMsats);

@override
String toString() {
  return 'EcashAppError.insufficientBalance(neededMsats: $neededMsats, haveMsats: $haveMsats)';
}


}

/// @nodoc
abstract mixin class $EcashAppError_InsufficientBalanceCopyWith<$Res> implements $EcashAppErrorCopyWith<$Res> {
  factory $EcashAppError_InsufficientBalanceCopyWith(EcashAppError_InsufficientBalance value, $Res Function(EcashAppError_InsufficientBalance) _then) = _$EcashAppError_InsufficientBalanceCopyWithImpl;
@useResult
$Res call({
 BigInt neededMsats, BigInt haveMsats
});




}
/// @nodoc
class _$EcashAppError_InsufficientBalanceCopyWithImpl<$Res>
    implements $EcashAppError_InsufficientBalanceCopyWith<$Res> {
  _$EcashAppError_InsufficientBalanceCopyWithImpl(this._self, this._then);

  final EcashAppError_InsufficientBalance _self;
  final $Res Function(EcashAppError_InsufficientBalance) _then;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? neededMsats = null,Object? haveMsats = null,}) {
  return _then(EcashAppError_InsufficientBalance(
neededMsats: null == neededMsats ? _self.neededMsats : neededMsats // ignore: cast_nullable_to_non_nullable
as BigInt,haveMsats: null == haveMsats ? _self.haveMsats : haveMsats // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class EcashAppError_NoRouteFound extends EcashAppError {
  const EcashAppError_NoRouteFound(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_NoRouteFound);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EcashAppError.noRouteFound()';
}


}




/// @nodoc


class EcashAppError_GatewayOffline extends EcashAppError {
  const EcashAppError_GatewayOffline(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_GatewayOffline);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EcashAppError.gatewayOffline()';
}


}




/// @nodoc


class EcashAppError_NoGatewaysAvailable extends EcashAppError {
  const EcashAppError_NoGatewaysAvailable(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_NoGatewaysAvailable);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EcashAppError.noGatewaysAvailable()';
}


}




/// @nodoc


class EcashAppError_FederationOffline extends EcashAppError {
  const EcashAppError_FederationOffline(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_FederationOffline);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EcashAppError.federationOffline()';
}


}




/// @nodoc


class EcashAppError_InvalidInvoice extends EcashAppError {
  const EcashAppError_InvalidInvoice(this.field0): super._();
  

 final  String field0;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EcashAppError_InvalidInvoiceCopyWith<EcashAppError_InvalidInvoice> get copyWith => _$EcashAppError_InvalidInvoiceCopyWithImpl<EcashAppError_InvalidInvoice>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_InvalidInvoice&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EcashAppError.invalidInvoice(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EcashAppError_InvalidInvoiceCopyWith<$Res> implements $EcashAppErrorCopyWith<$Res> {
  factory $EcashAppError_InvalidInvoiceCopyWith(EcashAppError_InvalidInvoice value, $Res Function(EcashAppError_InvalidInvoice) _then) = _$EcashAppError_InvalidInvoiceCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$EcashAppError_InvalidInvoiceCopyWithImpl<$Res>
    implements $EcashAppError_InvalidInvoiceCopyWith<$Res> {
  _$EcashAppError_InvalidInvoiceCopyWithImpl(this._self, this._then);

  final EcashAppError_InvalidInvoice _self;
  final $Res Function(EcashAppError_InvalidInvoice) _then;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EcashAppError_InvalidInvoice(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EcashAppError_InvalidEcash extends EcashAppError {
  const EcashAppError_InvalidEcash(this.field0): super._();
  

 final  String field0;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EcashAppError_InvalidEcashCopyWith<EcashAppError_InvalidEcash> get copyWith => _$EcashAppError_InvalidEcashCopyWithImpl<EcashAppError_InvalidEcash>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_InvalidEcash&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EcashAppError.invalidEcash(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EcashAppError_InvalidEcashCopyWith<$Res> implements $EcashAppErrorCopyWith<$Res> {
  factory $EcashAppError_InvalidEcashCopyWith(EcashAppError_InvalidEcash value, $Res Function(EcashAppError_InvalidEcash) _then) = _$EcashAppError_InvalidEcashCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$EcashAppError_InvalidEcashCopyWithImpl<$Res>
    implements $EcashAppError_InvalidEcashCopyWith<$Res> {
  _$EcashAppError_InvalidEcashCopyWithImpl(this._self, this._then);

  final EcashAppError_InvalidEcash _self;
  final $Res Function(EcashAppError_InvalidEcash) _then;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EcashAppError_InvalidEcash(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EcashAppError_EcashAlreadySpent extends EcashAppError {
  const EcashAppError_EcashAlreadySpent(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_EcashAlreadySpent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EcashAppError.ecashAlreadySpent()';
}


}




/// @nodoc


class EcashAppError_InvalidBitcoinAddress extends EcashAppError {
  const EcashAppError_InvalidBitcoinAddress(this.field0): super._();
  

 final  String field0;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EcashAppError_InvalidBitcoinAddressCopyWith<EcashAppError_InvalidBitcoinAddress> get copyWith => _$EcashAppError_InvalidBitcoinAddressCopyWithImpl<EcashAppError_InvalidBitcoinAddress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_InvalidBitcoinAddress&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EcashAppError.invalidBitcoinAddress(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EcashAppError_InvalidBitcoinAddressCopyWith<$Res> implements $EcashAppErrorCopyWith<$Res> {
  factory $EcashAppError_InvalidBitcoinAddressCopyWith(EcashAppError_InvalidBitcoinAddress value, $Res Function(EcashAppError_InvalidBitcoinAddress) _then) = _$EcashAppError_InvalidBitcoinAddressCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$EcashAppError_InvalidBitcoinAddressCopyWithImpl<$Res>
    implements $EcashAppError_InvalidBitcoinAddressCopyWith<$Res> {
  _$EcashAppError_InvalidBitcoinAddressCopyWithImpl(this._self, this._then);

  final EcashAppError_InvalidBitcoinAddress _self;
  final $Res Function(EcashAppError_InvalidBitcoinAddress) _then;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EcashAppError_InvalidBitcoinAddress(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EcashAppError_InvalidLightningAddress extends EcashAppError {
  const EcashAppError_InvalidLightningAddress(this.field0): super._();
  

 final  String field0;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EcashAppError_InvalidLightningAddressCopyWith<EcashAppError_InvalidLightningAddress> get copyWith => _$EcashAppError_InvalidLightningAddressCopyWithImpl<EcashAppError_InvalidLightningAddress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_InvalidLightningAddress&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EcashAppError.invalidLightningAddress(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EcashAppError_InvalidLightningAddressCopyWith<$Res> implements $EcashAppErrorCopyWith<$Res> {
  factory $EcashAppError_InvalidLightningAddressCopyWith(EcashAppError_InvalidLightningAddress value, $Res Function(EcashAppError_InvalidLightningAddress) _then) = _$EcashAppError_InvalidLightningAddressCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$EcashAppError_InvalidLightningAddressCopyWithImpl<$Res>
    implements $EcashAppError_InvalidLightningAddressCopyWith<$Res> {
  _$EcashAppError_InvalidLightningAddressCopyWithImpl(this._self, this._then);

  final EcashAppError_InvalidLightningAddress _self;
  final $Res Function(EcashAppError_InvalidLightningAddress) _then;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EcashAppError_InvalidLightningAddress(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EcashAppError_PaymentRefunded extends EcashAppError {
  const EcashAppError_PaymentRefunded(this.field0): super._();
  

 final  String field0;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EcashAppError_PaymentRefundedCopyWith<EcashAppError_PaymentRefunded> get copyWith => _$EcashAppError_PaymentRefundedCopyWithImpl<EcashAppError_PaymentRefunded>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_PaymentRefunded&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EcashAppError.paymentRefunded(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EcashAppError_PaymentRefundedCopyWith<$Res> implements $EcashAppErrorCopyWith<$Res> {
  factory $EcashAppError_PaymentRefundedCopyWith(EcashAppError_PaymentRefunded value, $Res Function(EcashAppError_PaymentRefunded) _then) = _$EcashAppError_PaymentRefundedCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$EcashAppError_PaymentRefundedCopyWithImpl<$Res>
    implements $EcashAppError_PaymentRefundedCopyWith<$Res> {
  _$EcashAppError_PaymentRefundedCopyWithImpl(this._self, this._then);

  final EcashAppError_PaymentRefunded _self;
  final $Res Function(EcashAppError_PaymentRefunded) _then;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EcashAppError_PaymentRefunded(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EcashAppError_Timeout extends EcashAppError {
  const EcashAppError_Timeout(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_Timeout);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EcashAppError.timeout()';
}


}




/// @nodoc


class EcashAppError_Other extends EcashAppError {
  const EcashAppError_Other(this.field0): super._();
  

 final  String field0;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EcashAppError_OtherCopyWith<EcashAppError_Other> get copyWith => _$EcashAppError_OtherCopyWithImpl<EcashAppError_Other>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EcashAppError_Other&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EcashAppError.other(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EcashAppError_OtherCopyWith<$Res> implements $EcashAppErrorCopyWith<$Res> {
  factory $EcashAppError_OtherCopyWith(EcashAppError_Other value, $Res Function(EcashAppError_Other) _then) = _$EcashAppError_OtherCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$EcashAppError_OtherCopyWithImpl<$Res>
    implements $EcashAppError_OtherCopyWith<$Res> {
  _$EcashAppError_OtherCopyWithImpl(this._self, this._then);

  final EcashAppError_Other _self;
  final $Res Function(EcashAppError_Other) _then;

/// Create a copy of EcashAppError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EcashAppError_Other(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
