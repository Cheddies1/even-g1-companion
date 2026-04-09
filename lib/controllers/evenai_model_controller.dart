import 'package:demo_ai_even/models/evenai_model.dart';
import 'package:get/get.dart';

class EvenaiModelController extends GetxController {
  var items = <EvenaiModel>[].obs;
  var selectedIndex = Rxn<int>();

  void addItem(String title, String content) {
    final newItem = EvenaiModel(title: title, content: content, createdTime: DateTime.now());
    items.insert(0, newItem);
  }

  void removeItem(int index) {
    items.removeAt(index);
    if (selectedIndex.value == index) {
      selectedIndex.value = null;
    } else if (selectedIndex.value != null && selectedIndex.value! > index) {
      selectedIndex.value = selectedIndex.value! - 1;
    }
  }

  void clearItems() {
    items.clear();
    selectedIndex.value = null;
  }

  void selectItem(int index) {
    selectedIndex.value = index;
  }

  void deselectItem() {
    selectedIndex.value = null;
  }
}