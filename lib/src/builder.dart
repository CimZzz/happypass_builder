import 'dart:async';
import 'dart:math';
import 'dart:mirrors';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:build/build.dart';

import 'annotations.dart';

PostProcessBuilder cleanBuilder(BuilderOptions options) =>
	const FileDeletingBuilder(['.happypass.part']);

Builder genBuilder([BuilderOptions options]) => _HappyPassBuilder();

class _HappyPassBuilder extends Builder {
	@override
	FutureOr<void> build(BuildStep buildStep) async {
		final inputId = buildStep.inputId;
		final library = await buildStep.inputLibrary.catchError((error) => null);
		if (library == null) {
			log.warning('${inputId.path} is not a completed dart source file(May be a part file), stop build this file');
			return;
		}
		final targetInput = inputId.changeExtension('.happypass.dart');
		final targetName = targetInput.pathSegments.last;
		// 第一步，检查 part 和 import
		final existPart = library.parts.map((unit) => unit.uri).contains(targetName);
		if (!existPart) {
			log.warning('${inputId.path} must declare: part: \'$targetName\';');
			return;
		}
		
		final existImport = library.imports.map((unit) => unit.uri).contains('package:happypass/happypass.dart');
		if (!existImport) {
			log.warning('${inputId.path} must declare: import: \'package:happypass/happypass.dart\';');
			return;
		}
		
		// 第二步，分析注解类
		// 只对顶级抽象类做分析，筛选
		final topClasses = library.topLevelElements.where((element) {
			// 选取顶级类，包括 Part File 中的顶级类
			if (element is ClassElement) {
				return element.isAbstract;
			}
			return false;
		}).map((element) => element as ClassElement);
		
		var doOutput = false;
		final buffer = StringBuffer();
		// 第三步，针对顶级类进行注解翻译
		for (var classElement in topClasses) {
			// 获取注解
			final annotations = classElement.metadata?.map((element) => element.computeConstantValue());
			if (annotations == null || annotations.isEmpty) {
				continue;
			}
			
			// 查找是否为 RequestFactory 注解
			final requestFactoryAnnotation = _findClassObj(objList: annotations, classType: RequestFactory);
			
			if (requestFactoryAnnotation != null) {
				// 注解为 RequestFactory
				if(await buildRequestFactory(_BuildContext(inputId, buffer, !doOutput, classElement))) {
					doOutput = true;
				}
			}
		}
		
		if(doOutput) {
			await buildStep.writeAsString(targetInput, buffer.toString());
		}
	}
	
	@override
	Map<String, List<String>> get buildExtensions =>
		const {
			'.dart': ['.happypass.dart']
		};
}

// 检查是否为该库中的类
bool _checkPackageClass(
	{Element element, Type classType, List<Type> types, Set<String> typeNames, String scheme, String packName = 'happypass_builder'}) {
	if (element == null || (classType == null && (types == null || types.isEmpty) && typeNames == null)) {
		return false;
	}
	final librarySource = element.librarySource;
	if (librarySource == null) {
		return false;
	}
	scheme ??= 'package';
	if (typeNames == null) {
		if (types != null) {
			typeNames = types.map((type) {
				final clsMirror = reflectClass(type);
				return MirrorSystem.getName(clsMirror.simpleName);
			}).toSet();
		}
		else {
			final clsMirror = reflectClass(classType);
			typeNames = {MirrorSystem.getName(clsMirror.simpleName)};
		}
	}
	if (librarySource.uriKind == UriKind.PACKAGE_URI) {
		final uri = librarySource.uri;
		if (uri != null
			&& uri.pathSegments != null
			&& uri.pathSegments.isNotEmpty
			&& uri.scheme == scheme
		) {
			if (uri.pathSegments.first == packName) {
				for (var typeName in typeNames) {
					if (element.name == typeName) {
						return true;
					}
				}
			}
		}
	}
	return false;
}

DartObject _findClassObj({Iterable<DartObject> objList, Type classType, List<Type> types}) {
	if (objList == null || (classType == null && (types == null || types.isEmpty))) {
		return null;
	}
	
	for (var obj in objList) {
		if (_checkPackageClass(element: obj.type.element, classType: classType, types: types)) {
			return obj;
		}
	}
	return null;
}

Set<Type> _findClassArr({Iterable<DartObject> objList, List<Type> types}) {
	if (objList == null || types == null || types.isEmpty) {
		return Iterable.empty();
	}
	
	final set = <Type>{};
	for (var obj in objList) {
		final element = obj.type.element;
		
		final librarySource = element.librarySource;
		if (librarySource.uriKind == UriKind.PACKAGE_URI) {
			final uri = librarySource.uri;
			if (uri != null && uri.pathSegments != null && uri.pathSegments.isNotEmpty) {
				if (uri.pathSegments.first == 'happypass_builder') {
					for (var classType in types) {
						final clsMirror = reflectClass(classType);
						if (clsMirror != null) {
							if (element.name == MirrorSystem.getName(clsMirror.simpleName)) {
								set.add(classType);
								break;
							}
						}
					}
				}
			}
		}
	}
	return set;
}

/// 构建文件上下文
class _BuildContext {
	_BuildContext(this.inputId, this.buffer, this.isFirstOutput, this.classElement);
	
	final AssetId inputId;
	final StringBuffer buffer;
	final bool isFirstOutput;
	final ClassElement classElement;
}

/// 暂时封装方法数据
class _MethodBundle {
	_MethodBundle({this.url, this.path, this.requestMethod, this.cryptChannel, this.isFormData, this.isMultipart, this.method});
	
	final String url;
	final String path;
	final _RequestMethod requestMethod;
	final _CryptChannel cryptChannel;
	final bool isFormData;
	final bool isMultipart;
	final MethodElement method;
}

/// 请求方法枚举
enum _RequestMethod {
	Get,
	Post
}

/// 数据编解码
enum _CryptChannel {
	Raw,
	String,
	JSON
}


/// 生成 RequestFactory 文件
Future<bool> buildRequestFactory(_BuildContext buildContext) async {
	final inputId = buildContext.inputId;
	final classElement = buildContext.classElement;
	final className = buildContext.classElement.name;
	final factoryName = '${className}Factory';
	final concretedName = '_${className}';
	final methodList = <_MethodBundle>[];
	// 遍历 Methods, 找到注解为 Post / Get 的抽象方法
	for (var method in classElement.methods) {
		// 判断是否为抽象方法
		if (!method.isAbstract) {
			continue;
		}
		
		if (!method.returnType.isDartAsyncFuture) {
			// 没有找到 Request 注释类
			log.warning('$className - ${method.name} : return type must be Future');
			return false;
		}
		
		// 获取注解
		final annotations = method.metadata?.map((element) => element.computeConstantValue());
		if (annotations == null || annotations.isEmpty) {
			continue;
		}
		
		final requestAnnotation = _findClassObj(objList: annotations, types: [Get, Post]);
		if (requestAnnotation == null) {
			// 没有找到 Request 注释类
			log.warning('$className - ${method.name} : need @Post / @Get annotation');
			return false;
		}
		final url = requestAnnotation.getField('url')?.toStringValue();
		final path = requestAnnotation.getField('path')?.toStringValue();
		final annoTypeSet = _findClassArr(objList: annotations, types: [FormData, Multipart, RawChannel, JSONChannel]);
		_RequestMethod requestMethod;
		var isFormData = annoTypeSet.contains(FormData);
		var isMultipart = annoTypeSet.contains(Multipart);
		var cryptChannel = _CryptChannel.String;
		if (annoTypeSet.contains(RawChannel)) {
			cryptChannel = _CryptChannel.Raw;
		}
		else if (annoTypeSet.contains(JSONChannel)) {
			cryptChannel = _CryptChannel.JSON;
		}
		
		var isValidTypeArgu = false;
		// 对返回类型再一次进行检测
		// 这次检测结合 cryptChannel 判断返回类型
		switch (cryptChannel) {
			case _CryptChannel.String:
			// 检查 StringChannel 返回值类型是否合法
			// 必须为 Future<List> , Future<Map> 或者 Future<ResultPassResponse>
				final returnElem = method.returnType as InterfaceType;
				final typeArguments = returnElem.typeArguments;
				if (typeArguments != null && typeArguments.isNotEmpty) {
					final typeElem = typeArguments[0];
					if (typeElem.isDynamic) {
						// 返回值类型不合法
						log.warning('$className - ${method.name} : string channel must return Future<String> or Future<ResultPassResponse>');
						return false;
					}
					if (_checkPackageClass(element: typeElem.element, scheme: 'dart', packName: 'core', types: [String])) {
						isValidTypeArgu = true;
						break;
					}
					if (_checkPackageClass(element: typeElem.element, packName: 'happypass', typeNames: {'ResultPassResponse'})) {
						isValidTypeArgu = true;
						break;
					}
				}
				
				if (!isValidTypeArgu) {
					// 返回值类型不合法
					log.warning('$className - ${method.name} : string channel must return Future<String> or Future<ResultPassResponse>');
					return false;
				}
				break;
			case _CryptChannel.JSON:
			// 检查 JSONChannel 返回值类型是否合法
			// 必须为 Future<List> , Future<Map> 或者 Future<ResultPassResponse>
				final returnElem = method.returnType as InterfaceType;
				final typeArguments = returnElem.typeArguments;
				if (typeArguments != null && typeArguments.isNotEmpty) {
					final typeElem = typeArguments[0];
					if (typeElem.isDynamic) {
						// 返回值类型不合法
						log.warning('$className - ${method.name} : json channel must return Future<String> or Future<ResultPassResponse>');
						return false;
					}
					if (_checkPackageClass(element: typeElem.element, scheme: 'dart', packName: 'core', types: [List, Map])) {
						isValidTypeArgu = true;
						break;
					}
					if (_checkPackageClass(element: typeElem.element, packName: 'happypass', typeNames: {'ResultPassResponse'})) {
						isValidTypeArgu = true;
						break;
					}
				}
				
				if (!isValidTypeArgu) {
					// 返回值类型不合法
					log.warning('$className - ${method.name} : json channel must return Future<List>、Future<Map> or Future<ResultPassResponse>');
					return false;
				}
				break;
			default:
			// 检查 RawData 返回值类型是否合法
			// 必须不为 Future(Future<dynamic>)
				final returnElem = method.returnType as InterfaceType;
				final typeArguments = returnElem.typeArguments;
				if (typeArguments != null && typeArguments.isNotEmpty) {
					final typeElem = typeArguments[0];
					if (typeElem.isDynamic) {
						// 返回值类型不合法
						log.warning('$className - ${method.name} : raw channel must not return Future(Future<dynamic>)');
						return false;
					}
					isValidTypeArgu = true;
				}
				break;
		}
		
		switch (requestAnnotation.type.element.name) {
			case 'Get':
				requestMethod = _RequestMethod.Get;
				break;
			case 'Post':
				requestMethod = _RequestMethod.Post;
				// 检测参数是否为空
				if (method.parameters == null || method.parameters.isEmpty) {
					// 没有找到 Request 注释类
					log.warning('$className - ${method.name} : parameters must not be null in post method');
					return false;
				}
				if (method.parameters.length > 1 && !isFormData && !isMultipart) {
					isFormData = true;
				}
				break;
		}
		
		
		methodList.add(_MethodBundle(
			url: url,
			path: path,
			requestMethod: requestMethod,
			cryptChannel: cryptChannel,
			isFormData: isFormData,
			isMultipart: isMultipart,
			method: method
		));
	}
	
	final buffer = buildContext.buffer;
	if(buildContext.isFirstOutput) {
		buffer.writeln('/// Generate by happypass_builder, Don\'t change anything by manual');
		buffer.writeln('part of \'${inputId.pathSegments.last}\';');
		buffer.writeln('');
		buffer.writeln('');
	}
	buffer.writeln('/// ################################################');
	buffer.writeln('/// Request Factory Implement of ${classElement.name}');
	buffer.writeln('/// ################################################');
	
	buffer.writeln('');
	buffer.writeln('/// Use for create $className instance');
	buffer.writeln('class $factoryName { // $factoryName start');
	buffer.writeln('');
	buffer.writeln('\t/// Private constructor');
	buffer.writeln('\t$factoryName._();');
	buffer.writeln('');
	buffer.writeln('\t/// Factory method. Create $className instance');
	buffer.writeln('\tstatic $className create({RequestPrototype prototype}) => $concretedName.requestPrototype(prototype);');
	buffer.writeln('');
	buffer.writeln('} // $factoryName end');
	buffer.writeln('');
	buffer.writeln('');
	buffer.writeln('class $concretedName extends $className { // $concretedName start');
	buffer.writeln('');
	buffer.writeln('\t/// Create Request Factory with Request Prototype');
	buffer.writeln('\t$concretedName.requestPrototype(RequestPrototype prototype): _prototype = prototype;');
	buffer.writeln('');
	buffer.writeln('\tfinal RequestPrototype _prototype;');
	for (final bundle in methodList) {
		buffer.writeln('');
		final method = bundle.method;
		final methodName = method.name;
		buffer.writeln('\t@override');
		buffer.writeln('\t${method.getDisplayString(withNullability: false)} async {');
		switch (bundle.requestMethod) {
		// GET
			case _RequestMethod.Get:
				buffer.writeln('\t\tfinal result = await happypass.get(');
				buffer.writeln('\t\t\turl: ${bundle.url != null ? '\'${bundle.url}\'' : 'null'},');
				buffer.writeln('\t\t\tpath: ${bundle.path != null ? '\'${bundle.path}\'' : 'null'},');
				buffer.writeln('\t\t\tprototype: _prototype,');
				buffer.writeln('\t\t\tconfigCallback: (Request request) {');
				final params = method.parameters;
				if (params != null && params.isNotEmpty) {
					params.forEach((param) {
						final name = param.name;
						buffer.writeln('\t\t\t\tif($name != null) {');
						buffer.writeln('\t\t\t\t\trequest.appendQueryParams(\'$name\', $name.toString());');
						buffer.writeln('\t\t\t\t}');
					});
				}
				break;
		// POST
			case _RequestMethod.Post:
				final params = method.parameters;
				if (bundle.isFormData) {
					buffer.writeln('\t\tfinal body = FormDataBody();');
					params.forEach((param) {
						final name = param.name;
						buffer.writeln('\t\tbody.addPair(\'$name\', $name);');
					});
				}
				else if (bundle.isMultipart) {
					buffer.writeln('\t\tfinal body = MultipartDataBody();');
					params.forEach((param) {
						final name = param.name;
						buffer.writeln('\t\tif($name != null) {');
						final paramLib = param.type.element.librarySource;
						final scheme = paramLib?.uri?.scheme;
						final first = paramLib?.uri?.pathSegments?.first;
						print('first: $first, scheme: $scheme');
						if (scheme == 'dart' && (first == 'io' || first == 'html')) {
							buffer.writeln('\t\t\tbody.addMultipartFile(\'$name\', $name);');
						}
						else {
							buffer.writeln('\t\t\tbody.addMultipartText(\'$name\', $name.toString());');
						}
						buffer.writeln('\t\t}');
					});
				}
				else {
					if (params.length == 1) {
						buffer.writeln('\t\tfinal body = ${params[0].name};');
					}
					else {
						// FormData
						buffer.writeln('\t\tfinal body = FormDataBody();');
						params.forEach((param) {
							final name = param.name;
							buffer.writeln('\t\tbody.addPair(\'$name\', $name.toString());');
						});
					}
				}
				
				buffer.writeln('\t\tfinal result = await happypass.post(');
				buffer.writeln('\t\t\turl: ${bundle.url != null ? '\'${bundle.url}\'' : 'null'},');
				buffer.writeln('\t\t\tpath: ${bundle.path != null ? '\'${bundle.path}\'' : 'null'},');
				buffer.writeln('\t\t\tbody: body,');
				buffer.writeln('\t\t\tprototype: _prototype,');
				buffer.writeln('\t\t\tconfigCallback: (Request request) {');
				break;
		}
		
		// config 部分
		switch (bundle.cryptChannel) {
			case _CryptChannel.String:
				buffer.writeln('\t\t\t\trequest.stringChannel();');
				break;
			case _CryptChannel.JSON:
				buffer.writeln('\t\t\t\trequest.jsonChannel();');
				break;
			default:
				break;
		}
		buffer.writeln('\t\t\t},');
		buffer.writeln('\t\t);');
		final returnElem = method.returnType as InterfaceType;
		final typeArguments = returnElem.typeArguments;
		if (typeArguments == null || typeArguments.isEmpty) {
			buffer.writeln('\t\treturn result;');
		}
		else {
			if (_checkPackageClass(element: typeArguments[0].element, packName: 'happypass', typeNames: {'ResultPassResponse'})) {
				buffer.writeln('\t\t');
				buffer.writeln('\t\treturn result;');
			}
			else {
				final typeStr = typeArguments[0].getDisplayString();
				buffer.writeln('\t\tif(result is SuccessPassResponse && result.body is $typeStr) {');
				buffer.writeln('\t\t\treturn result.body as $typeStr;');
				buffer.writeln('\t\t}');
				buffer.writeln('\t\t');
				buffer.writeln('\t\treturn null;');
			}
		}
		
		buffer.writeln('\t} // $methodName end');
		buffer.writeln('');
	}
	buffer.writeln('} // $concretedName end');
	buffer.writeln('');
	buffer.writeln('');
	return true;
}