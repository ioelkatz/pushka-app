import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const _svgVisa = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path fill="#FFFFFF" d="M9.112 8.262L5.97 15.758H3.92L2.374 9.775c-.094-.368-.175-.503-.461-.658C1.447 8.864.677 8.627 0 8.479l.046-.217h3.3a.904.904 0 01.894.764l.817 4.338 2.018-5.102zm8.033 5.049c.008-1.979-2.736-2.088-2.717-2.972.006-.269.262-.555.822-.628a3.66 3.66 0 011.913.336l.34-1.59a5.207 5.207 0 00-1.814-.333c-1.917 0-3.266 1.02-3.278 2.479-.012 1.079.963 1.68 1.698 2.04.756.367 1.01.603 1.006.931-.005.504-.602.725-1.16.734-.975.015-1.54-.263-1.992-.473l-.351 1.642c.453.208 1.289.39 2.156.398 2.037 0 3.37-1.006 3.377-2.564m5.061 2.447H24l-1.565-7.496h-1.656a.883.883 0 00-.826.55l-2.909 6.946h2.036l.405-1.12h2.488zm-2.163-2.656l1.02-2.815.588 2.815zm-8.16-4.84l-1.603 7.496H8.34l1.605-7.496z"/>
</svg>''';

const _svgMastercard = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 152 96">
  <circle cx="58" cy="48" r="40" fill="#EB001B"/>
  <circle cx="94" cy="48" r="40" fill="#F79E1B"/>
  <path d="M76,16.5 a40 40 0 0 1 0 63 a40 40 0 0 1 0 -63" fill="#FF5F00"/>
</svg>''';

const _svgAmex = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 36">
  <text x="50" y="25" text-anchor="middle" fill="#FFFFFF"
        font-family="Helvetica, Arial, sans-serif" font-weight="900"
        font-size="20" letter-spacing="1">AMEX</text>
</svg>''';

const _svgDiscover = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 130 30">
  <text x="65" y="22" text-anchor="middle" fill="#FFFFFF"
        font-family="Helvetica, Arial, sans-serif" font-weight="800"
        font-size="18" letter-spacing="1">DISCOVER</text>
</svg>''';

const _svgJcb = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 30">
  <text x="30" y="22" text-anchor="middle" fill="#FFFFFF"
        font-family="Helvetica, Arial, sans-serif" font-weight="900"
        font-size="20" letter-spacing="0.5">JCB</text>
</svg>''';

const _svgDinersClub = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 90 30">
  <text x="45" y="22" text-anchor="middle" fill="#FFFFFF"
        font-family="Helvetica, Arial, sans-serif" font-weight="800"
        font-size="16" letter-spacing="0.5">DINERS</text>
</svg>''';

Color cardBrandBg(String brand) {
  switch (brand.toLowerCase()) {
    case 'visa':        return const Color(0xFF1A1F71);
    case 'mastercard':  return const Color(0xFF111827);
    case 'amex':        return const Color(0xFF016FD0);
    case 'discover':    return const Color(0xFFFF6000);
    case 'jcb':         return const Color(0xFF0E4C92);
    case 'dinersclub':  return const Color(0xFF0079BE);
    default:            return const Color(0xFF374151);
  }
}

Widget cardBrandLogo(String brand) {
  switch (brand.toLowerCase()) {
    case 'visa':        return SvgPicture.string(_svgVisa,       width: 34, height: 22);
    case 'mastercard':  return SvgPicture.string(_svgMastercard, width: 24, height: 16);
    case 'amex':        return SvgPicture.string(_svgAmex,       width: 28, height: 12);
    case 'discover':    return SvgPicture.string(_svgDiscover,   width: 32, height: 10);
    case 'jcb':         return SvgPicture.string(_svgJcb,        width: 22, height: 12);
    case 'dinersclub':  return SvgPicture.string(_svgDinersClub, width: 28, height: 10);
    default:            return const Icon(Icons.credit_card, color: Colors.white, size: 18);
  }
}

String cardBrandLabel(String brand) {
  const labels = {
    'visa': 'Visa', 'mastercard': 'Mastercard', 'amex': 'Amex',
    'discover': 'Discover', 'jcb': 'JCB', 'unionpay': 'UnionPay', 'dinersclub': 'Diners',
  };
  return labels[brand.toLowerCase()] ?? brand;
}

Widget cardBrandBox(String brand) => Container(
  width: 40,
  height: 28,
  decoration: BoxDecoration(
    color: cardBrandBg(brand),
    borderRadius: BorderRadius.circular(6),
    border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1),
  ),
  alignment: Alignment.center,
  child: cardBrandLogo(brand),
);
