/// 为了防止歧义，建议在导入此文件时使用 `as`

/// Request Factory 注解常量
/// 可以直接使用此对象作为注解对象
const happyPassRequestFactory = RequestFactory._();

/// Request Factory 注解类
class RequestFactory {
	factory RequestFactory() => RequestFactory._();
	const RequestFactory._();
}


/// 请求方法抽象类
abstract class _Request {
    const _Request(this.url, this.path);

    /// 请求地址
	final String url;

	/// 请求路径
	final String path;
}


/// Post 请求方法
class Post extends _Request {
	const Post({String url, String path}): super(url, path);
}

/// Get 请求方法
class Get extends _Request {
	const Get({String url, String path}): super(url, path);
}

/// 表示请求体类型为 FormDataBody
class FormData {
	const FormData();
}

/// 表示请求体类型为 FormData-Multipart
class Multipart {
	const Multipart();
}